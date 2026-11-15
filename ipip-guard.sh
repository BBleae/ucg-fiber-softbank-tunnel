#!/bin/bash
# ipip-guard.sh — UniFi 原生 IPIP WAN（"IPv4 over IPv6 → IPIP → Transix"）的守护
#
# WAN1 的 IPv4 由 UniFi 自己建 ip6tnl 隧道承载，这个脚本只补 UniFi 的三个缺口:
#   1. 地址更新 URL 覆盖文件: Transix 选项在下发隧道参数前会先请求一次
#      "地址更新" URL，只有拿到 HTTP 响应才继续。这条线路是 SoftBank/BBIX，
#      所以把 URL 换成一个必然有响应的地址，占位凭据也不会发给 transix。
#   2. 隧道本地地址 (fix_local): udapi 用 eth4 的 DHCPv6 地址做隧道 local，
#      BR 只接受 "前缀|IID"。按 hb46pp 算出的参数把 local 钉在一个 udapi 不管理的
#      dummy 网卡上并改正隧道。
#   3. ubnt-hb46pp 不重试: 地址更新失败后要等 eth4 的 IPv6 地址变化才会再试。
#      已配置 IPIP 但隧道迟迟不出现时，补跑一次 provisioning。
#
# 部署: /data/ipip-guard.sh，由 ipip-guard.timer 每 15 秒运行

set -uo pipefail

IFACE="eth4"
CAP="ipip_internet_multifeed"
OVERRIDE="/data/udapi-config/internet_multifeed.${IFACE}.address_update"
UPDATE_URL="http://[2606:4700:4700::1111]/cdn-cgi/trace"
SERVER_FILE="/run/hb46pp/${IFACE}.server"
JSON_FILE="/run/hb46pp/${IFACE}.json"
ECM_DEFUNCT="/sys/kernel/debug/ecm/ecm_db/defunct_all"
PIN_DEV="ipipsrc0"
STATE_DIR="/run/ipip-guard"
LOG="/var/log/ipip-guard.log"
GRACE=60        # 隧道缺失超过这么久才补跑 (秒)
RETRY_GAP=300   # 两次补跑之间的最小间隔 (秒)

exec 9>/run/ipip-guard.lock
flock -n 9 || exit 0
mkdir -p "$STATE_DIR"

if [[ -f "$LOG" ]] && (( $(stat -c %s "$LOG" 2>/dev/null || echo 0) > 1048576 )); then
    mv -f "$LOG" "$LOG.old"
fi
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

now=$(cut -d. -f1 /proc/uptime)

# 隧道本地地址: hb46pp 算出的 local (前缀|IID) 是 BR 唯一接受的源地址，
# 但 udapi 建隧道时用的是 eth4 自己的 DHCPv6 地址。udapi 还会删掉它管理的接口上
# 它不认识的地址: eth4 在每次 DHCPv6 更新时，lo 在每次配置下发时 (任何 UI 改动)。
# 地址不在时内核拒绝发包 ("Local address not yet configured")，IPv4 中断到下一轮守护。
# 所以把 local 钉在 udapi 不管理的 dummy 网卡上，并在隧道 local 不对时改回来。
ensure_pin_dev() {
    if ! ip link show dev "$PIN_DEV" > /dev/null 2>&1; then
        if ! ip link add "$PIN_DEV" type dummy 2>/dev/null; then
            log "ERROR: cannot create $PIN_DEV"
            return 1
        fi
        ip link set dev "$PIN_DEV" addrgenmode none 2>/dev/null
        log "created dummy $PIN_DEV"
    fi
    ip link set dev "$PIN_DEV" up 2>/dev/null
}

fix_local() {
    local dev="$1" params mode local remote cur keep old a
    params=$(jq -r '.ip6tnl_parameters // empty' "$JSON_FILE" 2>/dev/null)
    IFS='|' read -r mode local remote _ <<< "$params"
    if [[ "$mode" != ipip || -z "$local" || -z "$remote" ]]; then
        return 0
    fi
    ensure_pin_dev || return 0

    if ! ip -6 addr show dev "$PIN_DEV" to "${local}/128" | grep -q inet6; then
        if ip -6 addr add "${local}/128" dev "$PIN_DEV" nodad 2>/dev/null; then
            log "pinned tunnel source $local on $PIN_DEV"
        else
            log "ERROR: cannot add $local to $PIN_DEV"
        fi
    fi

    # 新地址确认就位后再清理旧地址，中间不断流。按内核输出的写法比较，避免格式差异误删
    keep=$(ip -6 -o addr show dev "$PIN_DEV" to "${local}/128" | awk '{print $4; exit}')
    if [[ -n "$keep" ]]; then
        # 这块网卡只有本脚本使用: 前缀变化后留下的旧地址全部移除
        for a in $(ip -6 -o addr show dev "$PIN_DEV" scope global | awk '{print $4}'); do
            [[ "$a" == "$keep" ]] && continue
            ip -6 addr del "$a" dev "$PIN_DEV" 2>/dev/null && log "removed stale tunnel source $a from $PIN_DEV"
        done
        rm -f "$STATE_DIR/pin_addr"

        # 旧版本钉在 lo 上
        old=$(cat "$STATE_DIR/lo_addr" 2>/dev/null)
        for a in $old $local; do
            if ip -6 addr show dev lo to "${a}/128" | grep -q inet6; then
                ip -6 addr del "${a}/128" dev lo 2>/dev/null && log "removed tunnel source $a from lo"
            fi
        done
        rm -f "$STATE_DIR/lo_addr"
    fi

    cur=$(ip -d link show dev "$dev" 2>/dev/null | grep -oE ' local [^ ]+' | awk '{print $2}')
    if [[ "$cur" != "$local" ]]; then
        if ip link set dev "$dev" type ip6tnl mode any local "$local" remote "$remote" \
                encaplimit none hoplimit inherit 2>/dev/null; then
            log "set $dev local $cur -> $local"
            # NSS/ECM 已加速的连接缓存了旧的外层源地址，不刷新会继续发错包直到超时
            if [[ -w "$ECM_DEFUNCT" ]]; then
                echo 1 > "$ECM_DEFUNCT" && log "ECM connections defuncted"
            fi
        else
            log "ERROR: cannot set $dev local to $local"
        fi
    fi
}

# ─── 1. 地址更新 URL 覆盖文件 ───
if [[ "$(cat "$OVERRIDE" 2>/dev/null)" != "$UPDATE_URL" ]]; then
    if printf '%s\n' "$UPDATE_URL" > "$OVERRIDE.tmp" && mv -f "$OVERRIDE.tmp" "$OVERRIDE"; then
        log "address update override set to $UPDATE_URL"
    else
        log "ERROR: cannot write $OVERRIDE"
    fi
fi

# ─── 2. 隧道缺失时补跑 provisioning ───
# server 文件由 udapi 在 WAN1 配成 IPIP 时写入: IID|IPv6_Remote|IPv4_Address|IPv4_Prefix_Length
if [[ ! -s "$SERVER_FILE" ]]; then
    rm -f "$STATE_DIR/missing_since"
    exit 0
fi
IFS='|' read -r _ _ v4 _ < "$SERVER_FILE" || true
if [[ ! "$v4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log "ERROR: unexpected IPv4 field in $SERVER_FILE"
    exit 1
fi

dev=$(ip -4 -o addr show to "${v4}/32" 2>/dev/null | awk '{print $2; exit}')
if [[ -n "$dev" ]] && ip -d link show dev "$dev" 2>/dev/null | grep -qw ip6tnl; then
    if [[ -f "$STATE_DIR/missing_since" ]]; then
        log "tunnel $dev is up"
        rm -f "$STATE_DIR/missing_since"
    fi
    fix_local "$dev"
    exit 0
fi

if [[ ! -f "$STATE_DIR/missing_since" ]]; then
    echo "$now" > "$STATE_DIR/missing_since"
    log "IPIP configured on $IFACE but no tunnel carries $v4 yet"
    exit 0
fi
since=$(cat "$STATE_DIR/missing_since")
(( now - since >= GRACE )) || exit 0
if [[ -f "$STATE_DIR/last_kick" ]] && (( now - $(cat "$STATE_DIR/last_kick") < RETRY_GAP )); then
    exit 0
fi
echo "$now" > "$STATE_DIR/last_kick"

log "no tunnel for $((now - since))s, running one-shot hb46pp provisioning"
timeout 90 ubnt-hb46pp "$CAP" "$IFACE" -1 >> "$LOG" 2>&1
log "one-shot hb46pp exited with $?"
