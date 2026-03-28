#!/bin/bash
# tunnel-teardown.sh — 停止 IPIP 隧道、watchdog 并清除所有自定义规则
# 执行后路由器恢复为无自定义脚本的状态
# 用法: bash /data/tunnel-teardown.sh

set -euo pipefail

CONF="/data/tunnel.conf"
if [[ ! -f "$CONF" ]]; then
    echo "ERROR: config file $CONF not found" >&2
    exit 1
fi
source "$CONF"

LOG_PREFIX="[teardown]"
log() { echo "$LOG_PREFIX $(date): $*"; }

# ─── 1. 停止并禁用 watchdog timer ───
log "Stopping watchdog timer..."
systemctl stop tunnel-watchdog.timer 2>/dev/null || true
systemctl disable tunnel-watchdog.timer 2>/dev/null || true
systemctl stop tunnel-watchdog.service 2>/dev/null || true
log "Watchdog timer stopped and disabled."

# ─── 2. 先移除默认路由 (停止新流量) ───
log "Removing default route via $TUNNEL_NAME..."
ip route del default dev "$TUNNEL_NAME" 2>/dev/null || true

# ─── 3. 移除所有自定义 iptables 规则 ───
log "Removing custom iptables rules..."

# mangle: MSS clamping
iptables -w 10 -t mangle -D FORWARD -o "$TUNNEL_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

# nat: MASQUERADE (outbound)
iptables -w 10 -t nat -D POSTROUTING -o "$TUNNEL_NAME" -j MASQUERADE 2>/dev/null || true

# Port forward rules (from config)
for rule in "${PORT_FORWARDS[@]}"; do
    IFS=: read -r proto ext_port dest_ip dest_port <<< "$rule"
    # DNAT (external)
    iptables -w 10 -t nat -D PREROUTING -i "$TUNNEL_NAME" -p "$proto" --dport "$ext_port" -j DNAT --to-destination "${dest_ip}:${dest_port}" 2>/dev/null || true
    # Hairpin DNAT
    iptables -w 10 -t nat -D PREROUTING -i br0 -p "$proto" --dport "$ext_port" -d "$IPV4_ADDR" -j DNAT --to-destination "${dest_ip}:${dest_port}" 2>/dev/null || true
    # Hairpin MASQUERADE
    iptables -w 10 -t nat -D POSTROUTING -s "$LAN_SUBNET" -d "$dest_ip" -p "$proto" --dport "$dest_port" -j MASQUERADE 2>/dev/null || true
    # FORWARD allow
    iptables -w 10 -D FORWARD -i "$TUNNEL_NAME" -o br0 -p "$proto" --dport "$dest_port" -d "$dest_ip" -m state --state NEW -j ACCEPT 2>/dev/null || true
done

# FORWARD core rules
iptables -w 10 -D FORWARD -i br0 -o "$TUNNEL_NAME" -j ACCEPT 2>/dev/null || true
iptables -w 10 -D FORWARD -i "$TUNNEL_NAME" -o br0 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

# INPUT protection rules
iptables -w 10 -D INPUT -i "$TUNNEL_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -w 10 -D INPUT -i "$TUNNEL_NAME" -j DROP 2>/dev/null || true

log "All custom iptables rules removed."

# ─── 4. WAN hack + failover 规则清理 ───
ip rule del from "$DSLITE_SRC" lookup main prio 100 2>/dev/null || true
iptables -w 10 -t nat -D POSTROUTING -s "$DSLITE_SRC" -o "$TUNNEL_NAME" -j SNAT --to-source "$IPV4_ADDR" 2>/dev/null || true
# Remove WAN2 failover default route from main table (if active)
WAN2_GW=$(ip route show default 2>/dev/null | awk '/via/{print $3}')
[[ -n "$WAN2_GW" ]] && ip route del default via "$WAN2_GW" 2>/dev/null || true
log "WAN hack and failover rules removed."

# ─── 5. 关闭隧道 ───
log "Shutting down tunnel interface..."
ip link set "$TUNNEL_NAME" down 2>/dev/null || true
ip -6 tunnel del "$TUNNEL_NAME" 2>/dev/null || true

log "Removing tunnel source IPv6 from $TUNNEL_DEV..."
ip -6 addr del "${TUNNEL_SRC}/128" dev "$TUNNEL_DEV" 2>/dev/null || true

# ─── 6. 清理状态文件 ───
rm -f "$FAIL_COUNT_FILE" "${FAIL_COUNT_FILE}.tmp"
log "Tunnel torn down."

# ─── 7. 提示 ───
log "============================="
log "Teardown complete."
log "默认路由已移除，UniFi 系统应会自动恢复其管理的 WAN 路由。"
log ""
log "要重新启用隧道:"
log "  systemctl enable --now tunnel-watchdog.timer"
log "  /data/tunnel-watchdog.sh"
log "============================="
