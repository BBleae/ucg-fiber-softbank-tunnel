#!/bin/bash
# Tunnel watchdog v4.1 - IPIP6 tunnel + WAN status hack + metric-competition failover
# Runs every 15 seconds via systemd timer
#
# v4.1 (2026-08-19): 修复 v4 实现审查发现的 bug:
#   - metric 归一化: 启动时显式迁移 legacy metric-0 tun4 default -> metric 200 (先加后删, 不空窗)
#   - ensure_tun4_default 提前到健康检查前, 失败有日志 (修 H4)
#   - WAN2 验证拆两段: pre-route(carrier+网关) + post-install(route get + 公网 ping), 失败只回滚 WAN2 route (修 C1/H2)
#   - healthy 分支三态收敛: tun4 / eth6 / neither (修 C2)
#   - read_uint 校验持久化计数, corrupt 回退 0 (修 set -u 崩溃)
#   - dwell 用独立 timestamp 文件, 不依赖 marker (修 H3)
#   - 网关单候选 + unicast 校验 (修 H6)
#
# 核心不变量: tun4 default (metric 200) 始终保留, 永不删除.
#   failover  = 加 WAN2 default (metric 100, 更低=优先); 两条共存, 内核选 metric 100.
#   recovery  = 删 WAN2 那条, tun4 metric 200 自动接管.
#   (H4) ping -I tun4 健康检查永远有路由; (C1) 无 del-then-add 空窗; (C2) 每轮按 ip route get 收敛.

set -u

# --- 配置 ---
CONF="/data/tunnel.conf"
if [[ ! -f "$CONF" ]]; then
    echo "$(date): ERROR: config file $CONF not found" >&2
    exit 1
fi
source "$CONF"

# --- 单实例锁 ---
LOCKFILE="/var/run/tunnel-watchdog.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "$(date): another instance running, skipping" >> "$LOG"
    exit 0
fi

log() { echo "$(date): $*" >> "$LOG"; }

# --- 0. 日志轮转 ---
if [[ -f "$LOG" ]] && [[ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt "$MAX_LOG_BYTES" ]]; then
    mv "$LOG" "${LOG}.old"
    log "log rotated"
fi

# --- 配置变量 (含默认值, set -u 安全) ---
WAN2_DEV_CFG="${WAN2_DEV:-eth6}"
TUN_METRIC="${TUNNEL_ROUTE_METRIC:-200}"
W2_METRIC="${WAN2_ROUTE_METRIC:-100}"
FAILOVER_MIN_DWELL="${FAILOVER_MIN_DWELL_SEC:-60}"
RECOVER_OK_TH="${RECOVER_OK_THRESHOLD:-3}"
HEALTH_TO="${HEALTH_TIMEOUT:-3}"
FAILOVER_MARKER="/tmp/tun4-failover-active"
FAILOVER_TS_FILE="/tmp/tun4-failover-ts"      # dwell 时间戳, 独立于 marker
RECOVER_OK_FILE="/tmp/tun4-recover-ok-count"

# read_uint: 安全读取持久化数字, 只接受 ^[0-9]+$, 否则回退默认值 (修 set -u/arithmetic 崩溃)
read_uint() {  # $1=file $2=default
    local val
    val=$(cat "$1" 2>/dev/null || true)
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        printf '%s' "$val"
    else
        printf '%s' "$2"
    fi
}

# 验证 IPv4 单播 (H6): 排除 0/8, 127/8, 224-239/4 (组播), 255.255.255.255 等
is_unicast_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}" d="${BASH_REMATCH[4]}"
    for oct in "$a" "$b" "$c" "$d"; do
        (( oct >= 0 && oct <= 255 )) || return 1
    done
    (( a == 0 )) && return 1            # 0.0.0.0/8
    (( a == 127 )) && return 1           # loopback
    (( a >= 224 && a <= 239 )) && return 1  # multicast 224.0.0.0/4
    (( a == 255 && b == 255 && c == 255 && d == 255 )) && return 1  # broadcast
    return 0
}

# --- 1. Keep the tunnel source IPv6 on lo across UniFi WAN reprovisioning ---
# UniFi OS 6.0.17 may remove the static address from eth4 on each DHCPv4 leasefail.
# The ipip6 tunnel stays usable when its local IPv6 also exists on lo.
if ! ip -6 addr show dev lo to "${TUNNEL_SRC}/128" | grep -q 'inet6'; then
    if ip -6 addr add "${TUNNEL_SRC}/128" dev lo 2>/dev/null; then
        log "tunnel source IPv6 pinned on lo"
    elif ! ip -6 addr show dev lo to "${TUNNEL_SRC}/128" | grep -q 'inet6'; then
        log "ERROR: failed to pin tunnel source IPv6 on lo"
        exit 1
    fi
fi

# Keep eth4 configured as before; UniFi can still remove and restore this copy.
if ! ip -6 addr show dev "$TUNNEL_DEV" | grep -q "$TUNNEL_SRC"; then
    log "source IPv6 missing from $TUNNEL_DEV, re-adding"
    ip -6 addr add "${TUNNEL_SRC}/128" dev "$TUNNEL_DEV" 2>/dev/null
    sleep 1
fi

# --- 2. Ensure tunnel exists and is UP ---
if ! ip link show "$TUNNEL_NAME" up 2>/dev/null | grep -q UP; then
    log "tunnel down, recreating"
    ip link del "$TUNNEL_NAME" 2>/dev/null
    sleep 1

    if ! ip -6 addr show dev "$TUNNEL_DEV" | grep -q "$TUNNEL_SRC"; then
        ip -6 addr add "${TUNNEL_SRC}/128" dev "$TUNNEL_DEV" 2>/dev/null
        sleep 1
    fi

    if ! ip -6 tunnel add "$TUNNEL_NAME" mode ipip6 \
            local "$TUNNEL_SRC" remote "$TUNNEL_DST" \
            dev "$TUNNEL_DEV" encaplimit none; then
        log "ERROR: failed to create tunnel"
        exit 1
    fi
    if ! ip link set "$TUNNEL_NAME" mtu "$MTU" up; then
        log "ERROR: failed to bring tunnel up"
        exit 1
    fi
    ip addr add "${IPV4_ADDR}/32" dev "$TUNNEL_NAME" 2>/dev/null

    log "tunnel recreated by watchdog"
    echo 0 > "${FAIL_COUNT_FILE}.tmp" && mv "${FAIL_COUNT_FILE}.tmp" "$FAIL_COUNT_FILE"
fi

# --- 3. Ensure IPv4 address is on tunnel ---
if ! ip addr show "$TUNNEL_NAME" 2>/dev/null | grep -q "$IPV4_ADDR"; then
    log "IPv4 missing from tunnel, re-adding"
    ip addr add "${IPV4_ADDR}/32" dev "$TUNNEL_NAME" 2>/dev/null
fi

# --- 3a. Route model 归一化 (修 Critical: legacy metric-0 tun4 default) ---
# 先确保 metric-200 的 tun4 default 存在, 再删 legacy 无-metric/metric-0 的 tun4 default.
# 顺序: 先 add metric200 (保证有 default), 再 del 旧的 (不空窗, 因为 metric200 已在).
normalize_tun4_default() {
    # 加 metric-200 tun4 default (replace 幂等: 若已有同 metric 则替换, 若无则新增)
    ip route replace default dev "$TUNNEL_NAME" metric "$TUN_METRIC" 2>/dev/null
    # 删所有非 metric-200 的 tun4 default (v3 legacy 无-metric / 其他 metric 残留).
    # 枚举而非精确字符串匹配, 避免输出尾随空格等导致漏删 (实测: ^...$ 锚定会失败).
    # 先加 metric200 再删旧的, 保证不空窗.
    local removed=0
    while IFS= read -r line; do
        # line 形如 "default dev tun4 scope link" (无 metric) 或 "default dev tun4 scope link metric 50"
        # 跳过含本脚本 metric 的那条
        if [[ "$line" != *"metric $TUN_METRIC"* ]]; then
            # 提取该条目的 metric (若有) 用于精确 del
            local m
            m=$(echo "$line" | grep -oE 'metric [0-9]+' | awk '{print $2}')
            if [[ -n "$m" ]]; then
                ip route del default dev "$TUNNEL_NAME" metric "$m" 2>/dev/null && removed=$((removed+1))
            else
                # 无 metric (metric 0): del 时不带 metric
                ip route del default dev "$TUNNEL_NAME" 2>/dev/null && removed=$((removed+1))
            fi
        fi
    done < <(ip route show default 2>/dev/null | grep "dev $TUNNEL_NAME")
    if (( removed > 0 )); then
        log "route model: removed $removed legacy tun4 default route(s) (migrated to metric $TUN_METRIC)"
    fi
}
normalize_tun4_default

# --- 3b. eth4 IPv6 丢失保护: 连续丢失触发 udapi-server 重启 ---
# 背景 (2026-08-20): UCG-Fiber 5.1.19 的 hb46pp-eth4 (UniFi DS-Lite 客户端) 在
#   SoftBank 线路上反复崩溃 -> udapi watchdog 反复重启 -> 崩溃循环耗尽 CPU
#   (system time 66.7%, load 8) -> 控制面死机 (内网 ping 不通 192.168.1.1).
#   连带 odhcp6c 被 suspend/resume -> eth4 IPv6 源地址周期性丢失 -> tun4 隧道失效.
# 此保护: 检测到 eth4 的 TUNNEL_SRC IPv6 连续丢失 >= ETH4_IPV6_MISS_THRESHOLD 次
#   时, 触发 `systemctl restart udapi-server` (UniFi 自己的 WAN 管理), 打断崩溃循环.
#   带冷却期 (UDAPI_RESTART_COOLDOWN_SEC) 防重启风暴, 只记录日志不中断正常路径.
ETH4_MISS_FILE="/tmp/tun4-eth4-miss-count"
UDAPI_RESTART_TS_FILE="/tmp/tun4-udapi-restart-ts"
ETH4_MISS_THRESHOLD="${ETH4_IPV6_MISS_THRESHOLD:-4}"
UDAPI_RESTART_COOLDOWN="${UDAPI_RESTART_COOLDOWN_SEC:-300}"

# 检测 eth4 IPv6 源地址当前是否缺失 (仅检测, 实际 re-add 由下方第 4 节健康检查兜底)
eth4_src_missing=false
if ! ip -6 addr show dev "$TUNNEL_DEV" 2>/dev/null | grep -q "$TUNNEL_SRC"; then
    eth4_src_missing=true
fi

if $eth4_src_missing; then
    # 缺失: 累计连续次数
    ETH4_MISS=$(read_uint "$ETH4_MISS_FILE" 0)
    ETH4_MISS=$((ETH4_MISS + 1))
else
    ETH4_MISS=0
fi
echo "$ETH4_MISS" > "${ETH4_MISS_FILE}.tmp" && mv "${ETH4_MISS_FILE}.tmp" "$ETH4_MISS_FILE"

# 达到阈值且冷却期已过 -> 重启 udapi-server
if $eth4_src_missing && [[ "$ETH4_MISS" -ge "$ETH4_MISS_THRESHOLD" ]]; then
    last_restart=$(read_uint "$UDAPI_RESTART_TS_FILE" 0)
    now_ts=${EPOCHSECONDS:-$(date +%s)}
    if (( last_restart == 0 || now_ts - last_restart >= UDAPI_RESTART_COOLDOWN )); then
        log "WARN: eth4 IPv6 missing $ETH4_MISS consecutive checks; restarting udapi-server (hb46pp crash-loop mitigation)"
        # 内联快照 (snapshot_state 定义在后方, 此处不可用)
        log "  eth4-ipv6: $(ip -6 addr show dev "$TUNNEL_DEV" 2>/dev/null | grep inet6 | tr '\n' '|' || echo none)"
        # 重启 UniFi WAN 管理, 打断 hb46pp 崩溃循环. 用 timeout 防卡死.
        if timeout 30 systemctl restart udapi-server 2>/dev/null; then
            echo "$now_ts" > "${UDAPI_RESTART_TS_FILE}.tmp" && mv "${UDAPI_RESTART_TS_FILE}.tmp" "$UDAPI_RESTART_TS_FILE"
            echo 0 > "${ETH4_MISS_FILE}.tmp" && mv "${ETH4_MISS_FILE}.tmp" "$ETH4_MISS_FILE"
            log "udapi-server restarted (cooldown ${UDAPI_RESTART_COOLDOWN}s), IPv6 re-sync expected"
        else
            log "ERROR: udapi-server restart failed or timed out"
        fi
    fi
fi

# --- 3c. 确保 eth4 IPv6 RA 默认路由在 main 表 (static 模式修复) ---
# 背景 (2026-08-20): wan_type 从 dslite 改为 static 后, UniFi 把 eth4 的 IPv6 RA
#   默认路由放入 table 201.eth4 (策略路由表), main 表不再有 IPv6 默认路由.
#   -> LAN IPv6 出网断 (实测 ping6 100% loss). 也从 201.eth4 复制到 main 表后恢复 (0% loss).
# 每轮幂等: 若 main 表无 eth4 IPv6 默认, 且 201.eth4 表有, 则复制.
ensure_eth4_ipv6_default() {
    local ra_route
    # 已在 main 表: 正常, 直接返回 (每轮幂等, 静默)
    if ip -6 route show table main 2>/dev/null | grep -q "default.*dev $TUNNEL_DEV"; then
        return 0
    fi
    ra_route=$(ip -6 route show table 201.eth4 default 2>/dev/null | grep "via" | head -1)
    if [[ -n "$ra_route" ]]; then
        # 去掉 "table 201.eth4" 字样, 只保留 route 部分加到 main 表
        local clean
        clean=$(echo "$ra_route" | sed 's/ table 201\.eth4//')
        if ip -6 route add $clean 2>/dev/null; then
            # 防抖: 只有状态从"缺失"变成"已恢复"才记录, 避免 UniFi 周期性清表导致每15s刷日志
            local st_file="/tmp/tun4-eth4-ipv6-default-ok"
            if [[ ! -f "$st_file" ]]; then
                log "ipv6: copied eth4 RA default route to main table (LAN IPv6 out restored)"
                touch "$st_file"
            fi
        fi
    fi
}
ensure_eth4_ipv6_default

# --- 4. Tunnel health check (any target reachable = healthy) ---
# 注意: 健康检查在 normalize_tun4_default 之后, 保证 ping -I tun4 有路由 (H4).
health_ok=false
for target in "${HEALTH_TARGETS[@]}"; do
    if ping -I "$TUNNEL_NAME" -c 1 -W "$HEALTH_TO" "$target" >/dev/null 2>&1; then
        health_ok=true
        break
    fi
done

# --- 4a. Route helpers ---
ensure_tun4_default() {
    ip route replace default dev "$TUNNEL_NAME" metric "$TUN_METRIC" 2>/dev/null
}

# 解析 WAN2 网关: 多源 + token 化 + 单候选 + unicast 校验 (H6).
# 返回 0 并 stdout 网关, 或返回 1.
resolve_wan2_gw() {
    local candidates=() gw src
    # 源1: table 202.eth6 (UniFi 管理, 最新). -o 单行 + token 查 via.
    while IFS= read -r gw; do
        [[ -n "$gw" ]] && is_unicast_ipv4 "$gw" && candidates+=("$gw")
    done < <(ip -4 -o route show table 202.eth6 default 2>/dev/null \
             | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1)}}')
    if [[ ${#candidates[@]} -eq 1 ]]; then printf '%s\n' "${candidates[0]}"; return 0; fi
    # 源1 多候选或无: 不取 first, 降级到源2 (避免歧义)
    candidates=()
    # 源2: udhcpc lease 文件
    local lease="/data/udapi-config/ubios-udapi-server/udhcpc-ip.eth6"
    if [[ -f "$lease" ]]; then
        while IFS= read -r gw; do
            [[ -n "$gw" ]] && is_unicast_ipv4 "$gw" && candidates+=("$gw")
        done < <(grep -oE 'router[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$lease" 2>/dev/null | awk '{print $2}')
    fi
    if [[ ${#candidates[@]} -eq 1 ]]; then printf '%s\n' "${candidates[0]}"; return 0; fi
    # 源3: 硬编码 fallback (degraded, 必须经端到端验证)
    gw="${WAN2_GW_FALLBACK:-}"
    if [[ -n "$gw" ]] && is_unicast_ipv4 "$gw"; then
        printf '%s\n' "$gw"; return 0
    fi
    return 1
}

# WAN2 pre-route 验证 (carrier + 网关可达, 不修改路由). 返回 0/1.
verify_wan2_preroute() {
    local gw="$1"
    [[ "$(cat /sys/class/net/"$WAN2_DEV_CFG"/carrier 2>/dev/null)" == "1" ]] || return 1
    ip link show "$WAN2_DEV_CFG" 2>/dev/null | grep -q 'state UP' || return 1
    ping -I "$WAN2_DEV_CFG" -c 1 -W 2 "$gw" >/dev/null 2>&1 || return 1
    return 0
}

# WAN2 post-install 验证: route get 出口是 eth6 + 公网经 eth6 可达. 返回 0/1.
# 此时 WAN2 default 已装, tun4 default 仍在 (metric 200).
verify_wan2_postinstall() {
    egress_is "$WAN2_DEV_CFG" || return 1
    local t
    for t in 1.1.1.1 8.8.8.8; do
        ping -I "$WAN2_DEV_CFG" -c 1 -W 2 "$t" >/dev/null 2>&1 && return 0
    done
    return 1
}

# post-install 验证: ip route get 实际出口是预期 dev (H1/C3).
egress_is() {  # $1 = expected dev
    local target="${HEALTH_TARGETS[0]}"
    local got
    got=$(ip route get "$target" 2>/dev/null | grep -oE 'dev [^ ]+' | awk '{print $2}' | head -1)
    [[ "$got" == "$1" ]]
}

# 快照证据 (仅状态转换/错误时). 输出紧凑几行.
snapshot_state() {
    {
        echo "  default: $(ip route show default 2>/dev/null | tr '\n' '|')"
        echo "  table202.eth6: $(ip route show table 202.eth6 default 2>/dev/null | tr '\n' '|')"
        echo "  route-get ${HEALTH_TARGETS[0]}: $(ip route get "${HEALTH_TARGETS[0]}" 2>/dev/null | tr '\n' ' ')"
        echo "  tun4: $(ip -br link show "$TUNNEL_NAME" 2>/dev/null)"
    } 2>/dev/null
}

# --- 4b. 状态机: 每轮按实际内核状态收敛 (C2) ---
# 始终先保证 tun4 default (metric 200) 存在
if ! ensure_tun4_default; then
    log "ERROR: ensure_tun4_default failed (cannot install tun4 metric $TUN_METRIC)"
    snapshot_state | while IFS= read -r ln; do log "$ln"; done
    # 不退出: 继续尝试 failover 评估, 但记录异常
fi

if $health_ok; then
    # -- Tunnel HEALTHY --
    PREV_FAILS=$(read_uint "$FAIL_COUNT_FILE" 0)
    echo 0 > "${FAIL_COUNT_FILE}.tmp" && mv "${FAIL_COUNT_FILE}.tmp" "$FAIL_COUNT_FILE"

    # 恢复防抖 (H3): 连续健康计数
    RECOVER_OK=$(read_uint "$RECOVER_OK_FILE" 0)
    RECOVER_OK=$((RECOVER_OK + 1))
    echo "$RECOVER_OK" > "${RECOVER_OK_FILE}.tmp" && mv "${RECOVER_OK_FILE}.tmp" "$RECOVER_OK_FILE"

    # 三态判定 (C2): 看实际路由出口
    if egress_is "$WAN2_DEV_CFG"; then
        # 状态1: 处于 failover (出口 eth6)
        # dwell 检查 (H3): 用独立 timestamp 文件, 不依赖 marker
        DWELL_OK=true
        failover_ts=$(read_uint "$FAILOVER_TS_FILE" 0)
        if [[ "$failover_ts" -gt 0 ]]; then
            now_ts=${EPOCHSECONDS:-$(date +%s)}
            if (( now_ts - failover_ts < FAILOVER_MIN_DWELL )); then
                DWELL_OK=false
            fi
        fi
        if [[ "$RECOVER_OK" -ge "$RECOVER_OK_TH" ]] && $DWELL_OK; then
            log "tunnel recovered ($RECOVER_OK consecutive), restoring primary via $TUNNEL_NAME"
            # 删 WAN2 failover default (精确: dev eth6 + metric W2_METRIC)
            ip route del default dev "$WAN2_DEV_CFG" metric "$W2_METRIC" 2>/dev/null
            del_rc=$?
            if (( del_rc != 0 )); then
                # 可能 via 形式, 尝试带 gw
                wan2_gw_cur=$(ip route show default 2>/dev/null | grep "dev $WAN2_DEV_CFG" \
                              | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1);exit}}')
                [[ -n "$wan2_gw_cur" ]] && ip route del default via "$wan2_gw_cur" dev "$WAN2_DEV_CFG" metric "$W2_METRIC" 2>/dev/null
            fi
            # 验证恢复 (H1)
            if egress_is "$TUNNEL_NAME"; then
                rm -f "$FAILOVER_MARKER" "$FAILOVER_TS_FILE"
                echo 0 > "${RECOVER_OK_FILE}.tmp" && mv "${RECOVER_OK_FILE}.tmp" "$RECOVER_OK_FILE"
                log "WAN2 failover: deactivated, $TUNNEL_NAME is primary again"
                [[ "$PREV_FAILS" -ge "$FAIL_THRESHOLD" ]] && log "tunnel recovered after $PREV_FAILS failures"
            else
                log "ERROR: recovery verification failed, egress not $TUNNEL_NAME"
                snapshot_state | while IFS= read -r ln; do log "$ln"; done
            fi
        fi
        # 防抖未达标: 静默
    elif egress_is "$TUNNEL_NAME"; then
        # 状态2: 正常 primary (出口 tun4). 清理可能残留的 failover 状态.
        rm -f "$FAILOVER_MARKER" "$FAILOVER_TS_FILE"
        echo 0 > "${RECOVER_OK_FILE}.tmp" && mv "${RECOVER_OK_FILE}.tmp" "$RECOVER_OK_FILE" 2>/dev/null
    else
        # 状态3: neither (异常, 出口既非 tun4 也非 eth6). 不清状态, 告警.
        log "WARN: egress is neither $TUNNEL_NAME nor $WAN2_DEV_CFG (route model anomaly)"
        snapshot_state | while IFS= read -r ln; do log "$ln"; done
    fi
else
    # -- Tunnel UNHEALTHY --
    FAILS=$(read_uint "$FAIL_COUNT_FILE" 0)
    FAILS=$((FAILS + 1))
    echo "$FAILS" > "${FAIL_COUNT_FILE}.tmp" && mv "${FAIL_COUNT_FILE}.tmp" "$FAIL_COUNT_FILE"
    echo 0 > "${RECOVER_OK_FILE}.tmp" && mv "${RECOVER_OK_FILE}.tmp" "$RECOVER_OK_FILE" 2>/dev/null

    if [[ $FAILS -ge "$FAIL_THRESHOLD" ]]; then
        # 已 failover 了吗? 看实际路由出口 (C2: 不信任 marker)
        if egress_is "$WAN2_DEV_CFG"; then
            : # 已切到 WAN2 且实际生效, 已收敛 (每轮都查, 不跳过修复)
        else
            # 需要激活 failover. 先解析网关 (H6)
            WAN2_GW=$(resolve_wan2_gw || true)
            if [[ -z "${WAN2_GW:-}" ]]; then
                log "WAN2 failover: ERROR - cannot resolve WAN2 gateway (no single valid candidate)"
                snapshot_state | while IFS= read -r ln; do log "$ln"; done
            elif ! verify_wan2_preroute "$WAN2_GW"; then
                # C1/H2 pre-route: 验证失败 -> 不装 WAN2 route, tun4 default 仍在 (metric 200)
                log "WAN2 failover: WAN2 preroute failed (gw=$WAN2_GW), staying on $TUNNEL_NAME"
                snapshot_state | while IFS= read -r ln; do log "$ln"; done
            else
                # 事务化切换: 装 WAN2 default (metric 100 < tun4 200), tun4 保留
                if ip route replace default via "$WAN2_GW" dev "$WAN2_DEV_CFG" metric "$W2_METRIC" 2>/dev/null; then
                    # post-install 验证 (H1/C3/H2): route get + 公网 ping
                    if verify_wan2_postinstall; then
                        now_ts=${EPOCHSECONDS:-$(date +%s)}
                        echo "$now_ts" > "$FAILOVER_TS_FILE.tmp" && mv "$FAILOVER_TS_FILE.tmp" "$FAILOVER_TS_FILE"
                        echo "$now_ts" > "$FAILOVER_MARKER.tmp" && mv "$FAILOVER_MARKER.tmp" "$FAILOVER_MARKER"
                        log "WAN2 failover: activated default via $WAN2_GW dev $WAN2_DEV_CFG metric $W2_METRIC (tun4 kept metric $TUN_METRIC)"
                        snapshot_state | while IFS= read -r ln; do log "$ln"; done
                    else
                        # post-install 失败: 回滚 WAN2 route (只删 WAN2, 保留 tun4)
                        log "ERROR: failover post-install verification failed, reverting WAN2 route"
                        ip route del default via "$WAN2_GW" dev "$WAN2_DEV_CFG" metric "$W2_METRIC" 2>/dev/null
                        snapshot_state | while IFS= read -r ln; do log "$ln"; done
                    fi
                else
                    log "ERROR: ip route replace WAN2 default failed (gw=$WAN2_GW)"
                    snapshot_state | while IFS= read -r ln; do log "$ln"; done
                fi
            fi
        fi
    else
        log "tunnel health check failed ($FAILS/$FAIL_THRESHOLD)"
    fi
fi

# --- 5. Firewall rules (idempotent) ---
ipt_add() {
    iptables -w 10 "$@" 2>/dev/null
}

# Core tunnel rules
ipt_add -C FORWARD -i br0 -o "$TUNNEL_NAME" -j ACCEPT || ipt_add -A FORWARD -i br0 -o "$TUNNEL_NAME" -j ACCEPT
ipt_add -C FORWARD -i "$TUNNEL_NAME" -o br0 -m state --state ESTABLISHED,RELATED -j ACCEPT || ipt_add -A FORWARD -i "$TUNNEL_NAME" -o br0 -m state --state ESTABLISHED,RELATED -j ACCEPT
ipt_add -t mangle -C FORWARD -o "$TUNNEL_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || ipt_add -t mangle -A FORWARD -o "$TUNNEL_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ipt_add -t nat -C POSTROUTING -o "$TUNNEL_NAME" -j MASQUERADE || ipt_add -t nat -A POSTROUTING -o "$TUNNEL_NAME" -j MASQUERADE
# INSERT at top of INPUT chain (must precede the DROP rule below)
ipt_add -C INPUT -i "$TUNNEL_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT || iptables -w 10 -I INPUT -i "$TUNNEL_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT
ipt_add -C INPUT -i "$TUNNEL_NAME" -j DROP || ipt_add -A INPUT -i "$TUNNEL_NAME" -j DROP

# --- 6. WAN status hack: route ip6tnl1 health checks through tunnel ---
ip rule show | grep -q "from $DSLITE_SRC lookup main" || {
    ip rule add from "$DSLITE_SRC" lookup main prio 100
    log "WAN hack: added ip rule for $DSLITE_SRC"
}
ipt_add -t nat -C POSTROUTING -s "$DSLITE_SRC" -o "$TUNNEL_NAME" -j SNAT --to-source "$IPV4_ADDR" || {
    ipt_add -t nat -A POSTROUTING -s "$DSLITE_SRC" -o "$TUNNEL_NAME" -j SNAT --to-source "$IPV4_ADDR"
    log "WAN hack: added SNAT rule for $DSLITE_SRC"
}

# --- 7. Fix miniupnpd external interface (ubios generates wrong ext_ifname) ---
UPNPD_CONF="/run/miniupnpd.conf"
if [[ -f "$UPNPD_CONF" ]] && grep -q "^ext_ifname=ip6tnl1" "$UPNPD_CONF"; then
    log "miniupnpd: ext_ifname=ip6tnl1 detected, patching to $TUNNEL_NAME"
    sed -i "s|^ext_ifname=ip6tnl1|ext_ifname=$TUNNEL_NAME|" "$UPNPD_CONF"
    # Also ensure ext_ip is explicit (tun4 is a p2p if, miniupnpd may not read it correctly)
    if ! grep -q "^ext_ip=" "$UPNPD_CONF"; then
        echo "ext_ip=$IPV4_ADDR" >> "$UPNPD_CONF"
    else
        sed -i "s|^ext_ip=.*|ext_ip=$IPV4_ADDR|" "$UPNPD_CONF"
    fi
    # Restart miniupnpd with the corrected config
    if kill -HUP "$(cat /var/run/miniupnpd.pid 2>/dev/null)" 2>/dev/null; then
        log "miniupnpd: sent SIGHUP to reload config"
    else
        # SIGHUP not supported on some builds; kill and let systemd restart it
        pkill -x miniupnpd 2>/dev/null && log "miniupnpd: restarted with correct ext_ifname=$TUNNEL_NAME"
    fi
fi

# --- 8. Port forwarding rules (from config, idempotent) ---
# 端口可写 "起-止" 范围: 内外网范围必须相同, DNAT 不带端口 => 内核不改端口, 原样映射
# 设置全局 proto dest_ip ext_match dest_match dnat_to; 规则无效返回 1
parse_forward() {
    local ext_port dest_port
    IFS=: read -r proto ext_port dest_ip dest_port <<< "$1"
    ext_match="${ext_port/-/:}"
    dest_match="${dest_port/-/:}"
    if [[ "$ext_port" == *-* || "$dest_port" == *-* ]]; then
        [[ "$ext_port" == "$dest_port" && "$ext_port" =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
        (( 10#${BASH_REMATCH[1]} <= 10#${BASH_REMATCH[2]} && 10#${BASH_REMATCH[2]} <= 65535 )) || return 1
        dnat_to="$dest_ip"
    else
        dnat_to="${dest_ip}:${dest_port}"
    fi
}

PF_WARNED="/tmp/tun4-pf-invalid-warned"   # 防抖: 每条无效规则每次开机只记一次
for rule in "${PORT_FORWARDS[@]}"; do
    if ! parse_forward "$rule"; then
        if ! grep -qxF -- "$rule" "$PF_WARNED" 2>/dev/null; then
            log "port forward: invalid rule '$rule' (range must be lo-hi, identical on both sides), skipped"
            echo "$rule" >> "$PF_WARNED"
        fi
        continue
    fi
    # DNAT (external -> internal)
    ipt_add -t nat -C PREROUTING -i "$TUNNEL_NAME" -p "$proto" --dport "$ext_match" -j DNAT --to-destination "$dnat_to" || \
        ipt_add -t nat -A PREROUTING -i "$TUNNEL_NAME" -p "$proto" --dport "$ext_match" -j DNAT --to-destination "$dnat_to"
    # FORWARD allow for new connections
    ipt_add -C FORWARD -i "$TUNNEL_NAME" -o br0 -p "$proto" --dport "$dest_match" -d "$dest_ip" -m state --state NEW -j ACCEPT || \
        ipt_add -A FORWARD -i "$TUNNEL_NAME" -o br0 -p "$proto" --dport "$dest_match" -d "$dest_ip" -m state --state NEW -j ACCEPT
    # Hairpin NAT: LAN access via public IP
    ipt_add -t nat -C PREROUTING -i br0 -p "$proto" --dport "$ext_match" -d "$IPV4_ADDR" -j DNAT --to-destination "$dnat_to" || \
        ipt_add -t nat -A PREROUTING -i br0 -p "$proto" --dport "$ext_match" -d "$IPV4_ADDR" -j DNAT --to-destination "$dnat_to"
    ipt_add -t nat -C POSTROUTING -s "$LAN_SUBNET" -d "$dest_ip" -p "$proto" --dport "$dest_match" -j MASQUERADE || \
        ipt_add -t nat -A POSTROUTING -s "$LAN_SUBNET" -d "$dest_ip" -p "$proto" --dport "$dest_match" -j MASQUERADE
done
