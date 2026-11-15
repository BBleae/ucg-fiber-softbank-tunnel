#!/bin/bash
# native-ipip-rollback.sh — 从 UniFi 原生 IPIP 回到自建 tun4 方案
#
# 用法:
#   bash /data/native-ipip-rollback.sh --now    # 手动回滚
#   (--auto 由 native-ipip-cutover.sh 的 30 分钟计时器调用; 已 commit 时不动作)
#
# 原生隧道还在时不会回滚: 它与 tun4 的 local/remote 相同，内核不允许并存。
# 这时要先在 UniFi UI 里把 WAN1 的 IPv4 改回切换前的设置 (见切换快照里的
# network_conf-wan.json，原来的 wan_type 是 ipv6)，再运行本脚本。

set -uo pipefail

BASE=/data/ipip-cutover
HOOK_DROPIN=/etc/systemd/system/udapi-server.service.d/wan-hook.conf
ONBOOT_DISABLED=/data/on_boot.d.disabled/10-tunnel-setup.sh
LOGFILE="$BASE/cutover.log"
mkdir -p "$BASE"
log() { echo "$(date '+%F %T') [rollback] $*" | tee -a "$LOGFILE"; }

MODE="${1:-}"
case "$MODE" in
    --now|--auto) ;;
    *) echo "usage: $0 --now|--auto" >&2; exit 1 ;;
esac

if [[ "$MODE" == --auto && -f "$BASE/committed" ]]; then
    exit 0
fi

source /data/tunnel.conf

native=$(ip -4 -o addr show to "${IPV4_ADDR}/32" 2>/dev/null | awk -v t="$TUNNEL_NAME" '$2 != t {print $2; exit}')
if [[ -n "$native" ]]; then
    log "native tunnel $native still carries the public IPv4; revert WAN1 IPv4 in the UniFi UI to its pre-cutover setting (network_conf-wan.json in the cutover snapshot) first, then run: bash $0 --now"
    exit 2
fi

log "rolling back to tun4 ($MODE)"

systemctl disable --now ipip-guard.timer 2>/dev/null
# 等正在运行的守护结束，否则它可能在删除后又把 dummy 建回来
systemctl stop ipip-guard.service 2>/dev/null
flock -w 100 /run/ipip-guard.lock ip link del ipipsrc0 2>/dev/null

mkdir -p "$(dirname "$HOOK_DROPIN")"
cp -f /data/wan-hook.conf "$HOOK_DROPIN"
if [[ -f "$ONBOOT_DISABLED" ]]; then
    mkdir -p /data/on_boot.d
    mv -f "$ONBOOT_DISABLED" /data/on_boot.d/
fi
cp -f /data/tunnel-watchdog.service /data/tunnel-watchdog.timer /etc/systemd/system/
systemctl daemon-reload
systemctl restart udapi-server
for _ in $(seq 1 60); do
    ubios-udapi-client GET /interfaces > /dev/null 2>&1 && break
    sleep 1
done

systemctl enable --now tunnel-watchdog.timer
sleep 5
bash /data/tunnel-watchdog.sh >> "$LOGFILE" 2>&1

if ping -c 3 -W 2 -I "$TUNNEL_NAME" 1.1.1.1 > /dev/null 2>&1; then
    log "rollback done, $TUNNEL_NAME is passing traffic"
else
    log "rollback done but $TUNNEL_NAME ping failed; check /var/log/tunnel-watchdog.log"
fi
