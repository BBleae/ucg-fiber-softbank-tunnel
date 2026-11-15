#!/bin/bash
# native-ipip-cutover.sh — 从自建 tun4 切换到 UniFi 原生 IPIP WAN
#
# 用法 (在路由器上，用 systemd-run 脱离 ssh 会话运行):
#   systemd-run --unit=ipip-cutover --collect /bin/bash /data/native-ipip-cutover.sh prepare
#   (在 UniFi UI 把 WAN1 的 IPv4 改成 IPIP，确认一切正常后)
#   bash /data/native-ipip-cutover.sh commit
#
# prepare: 快照现状 → 武装 30 分钟自动回滚 → 停 watchdog、拆 tun4、
#          移除 LD_PRELOAD hook 并重启 udapi → 安装 ipip-guard。
#          此时 LAN 的 IPv4 走 Starlink，等待 UI 改配置。
#          任何一步失败立即回滚。
# commit:  确认切换，取消自动回滚。
#
# 自动回滚只在原生隧道没有建起来时才会执行 (见 native-ipip-rollback.sh)。

set -uo pipefail

BASE=/data/ipip-cutover
DEADMAN_UNIT=ipip-cutover-deadman
HOOK_DROPIN=/etc/systemd/system/udapi-server.service.d/wan-hook.conf
ONBOOT=/data/on_boot.d/10-tunnel-setup.sh
ONBOOT_DISABLED=/data/on_boot.d.disabled
OVERRIDE=/data/udapi-config/internet_multifeed.eth4.address_update
UPDATE_URL="http://[2606:4700:4700::1111]/cdn-cgi/trace"

mkdir -p "$BASE"
LOGFILE="$BASE/cutover.log"
log() { echo "$(date '+%F %T') [cutover] $*" | tee -a "$LOGFILE"; }

snapshot() {
    local dir="$1"
    mkdir -p "$dir"
    cp -aL /data/udapi-config/udapi-net-cfg.json "$dir/" 2>/dev/null
    cp -a /data/udapi-config/ubios-udapi-server/ubios-udapi-server.state "$dir/" 2>/dev/null
    cp -a "$HOOK_DROPIN" "$dir/" 2>/dev/null
    iptables-save > "$dir/iptables-save.txt" 2>&1
    ip6tables-save > "$dir/ip6tables-save.txt" 2>&1
    {
        ip -d link show; echo; ip addr; echo
        ip rule; echo; ip -6 rule; echo
        ip route show table all; echo; ip -6 route show table all
    } > "$dir/ip.txt" 2>&1
    su postgres -s /bin/sh -c "psql -h /run/postgresql -p 5434 -d unifi-network -Atc \"select row_to_json(n) from config.network_conf n where purpose='wan'\"" \
        > "$dir/network_conf-wan.json" 2>&1
    systemctl list-timers --all > "$dir/timers.txt" 2>&1
}

wait_udapi() {
    local i
    for i in $(seq 1 60); do
        if ubios-udapi-client GET /interfaces > /dev/null 2>&1; then return 0; fi
        sleep 1
    done
    return 1
}

prepare() {
    local ts dir
    ts=$(date +%Y%m%d-%H%M%S)
    dir="$BASE/$ts"
    log "=== prepare ($dir) ==="

    for f in /data/ipip-guard.sh /data/ipip-guard.service /data/ipip-guard.timer \
             /data/native-ipip-rollback.sh /data/tunnel-teardown.sh /data/tunnel-watchdog.sh \
             /data/wan-hook.conf /data/tunnel.conf; do
        [[ -f "$f" ]] || { log "missing $f, abort (nothing changed)"; exit 1; }
    done
    rm -f "$BASE/committed"

    snapshot "$dir"
    log "snapshot saved"

    # 自动回滚: 30 分钟后若未 commit 且原生隧道不存在，则恢复 tun4 方案
    systemctl stop "$DEADMAN_UNIT.timer" "$DEADMAN_UNIT.service" 2>/dev/null
    systemctl reset-failed "$DEADMAN_UNIT.service" 2>/dev/null
    # 绝对时间: 相对时间 (--on-active) 会被之后的 daemon-reload 重新计时
    if ! systemd-run --unit="$DEADMAN_UNIT" --on-calendar="$(date -d '+30 min' '+%F %T')" \
            /bin/bash /data/native-ipip-rollback.sh --auto > /dev/null 2>&1; then
        log "cannot arm auto-rollback timer, abort (nothing changed)"
        exit 1
    fi
    log "auto-rollback armed (30 min)"

    trap 'rc=$?; if (( rc != 0 )); then log "prepare failed (rc=$rc), rolling back now"; bash /data/native-ipip-rollback.sh --now; fi' EXIT

    # 1. 停 watchdog 与开机恢复脚本
    systemctl disable --now tunnel-watchdog.timer
    systemctl stop tunnel-watchdog.service 2>/dev/null
    if [[ -f "$ONBOOT" ]]; then
        mkdir -p "$ONBOOT_DISABLED"
        mv -f "$ONBOOT" "$ONBOOT_DISABLED/" || exit 1
        log "on_boot script moved to $ONBOOT_DISABLED"
    fi

    # 2. 拆 tun4 和全部自定义规则
    bash /data/tunnel-teardown.sh >> "$LOGFILE" 2>&1 || { log "teardown failed"; exit 1; }
    if ip link show tun4 > /dev/null 2>&1; then log "tun4 still exists"; exit 1; fi
    log "tun4 torn down"

    # 3. 移除 LD_PRELOAD hook 并重启 udapi
    rm -f "$HOOK_DROPIN"
    systemctl daemon-reload
    systemctl restart udapi-server || { log "udapi restart failed"; exit 1; }
    wait_udapi || { log "udapi did not come back"; exit 1; }
    if tr '\0' '\n' < "/proc/$(systemctl show -p MainPID --value udapi-server)/environ" 2>/dev/null | grep -q '^LD_PRELOAD='; then
        log "udapi still has LD_PRELOAD"; exit 1
    fi
    log "udapi restarted without hook"

    # 4. 安装 ipip-guard (未配置 IPIP 时它只维护覆盖文件)
    printf '%s\n' "$UPDATE_URL" > "$OVERRIDE"
    cp -f /data/ipip-guard.service /data/ipip-guard.timer /etc/systemd/system/
    chmod +x /data/ipip-guard.sh
    systemctl daemon-reload
    systemctl enable --now ipip-guard.timer || { log "cannot enable ipip-guard.timer"; exit 1; }
    log "ipip-guard enabled"

    # 5. 确认 IPv4 已经由 UniFi 转到 WAN2
    local i ok=0
    for i in $(seq 1 30); do
        if ping -c 1 -W 2 1.1.1.1 > /dev/null 2>&1; then ok=1; break; fi
        sleep 2
    done
    if (( ok )); then
        log "IPv4 reachable via $(ip route get 1.1.1.1 2>/dev/null | head -1)"
    else
        log "WARNING: router IPv4 unreachable, change UI now or roll back"
    fi

    trap - EXIT
    log "=== prepare done. Change WAN1 IPv4 to IPIP in the UniFi UI now. ==="
}

commit() {
    touch "$BASE/committed"
    systemctl stop "$DEADMAN_UNIT.timer" "$DEADMAN_UNIT.service" 2>/dev/null
    log "committed, auto-rollback cancelled"
}

case "${1:-}" in
    prepare) prepare ;;
    commit) commit ;;
    *) echo "usage: $0 prepare|commit" >&2; exit 1 ;;
esac
