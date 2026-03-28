#!/bin/bash
# Tunnel watchdog v3 - IPIP6 tunnel + WAN status hack + failover support
# Runs every 15 seconds via systemd timer

set -u

# ─── 配置 ───
CONF="/data/tunnel.conf"
if [[ ! -f "$CONF" ]]; then
    echo "$(date): ERROR: config file $CONF not found" >&2
    exit 1
fi
source "$CONF"

# ─── 单实例锁 ───
LOCKFILE="/var/run/tunnel-watchdog.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "$(date): another instance running, skipping" >> "$LOG"
    exit 0
fi

log() { echo "$(date): $*" >> "$LOG"; }

# ─── 0. 日志轮转 ───
if [[ -f "$LOG" ]] && [[ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt "$MAX_LOG_BYTES" ]]; then
    mv "$LOG" "${LOG}.old"
    log "log rotated"
fi

# ─── 1. Ensure tunnel source IPv6 is on the physical interface ───
if ! ip -6 addr show dev "$TUNNEL_DEV" | grep -q "$TUNNEL_SRC"; then
    log "source IPv6 missing from $TUNNEL_DEV, re-adding"
    ip -6 addr add "${TUNNEL_SRC}/128" dev "$TUNNEL_DEV" 2>/dev/null
    sleep 1
fi

# ─── 2. Ensure tunnel exists and is UP ───
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

# ─── 3. Ensure IPv4 address is on tunnel ───
if ! ip addr show "$TUNNEL_NAME" 2>/dev/null | grep -q "$IPV4_ADDR"; then
    log "IPv4 missing from tunnel, re-adding"
    ip addr add "${IPV4_ADDR}/32" dev "$TUNNEL_NAME" 2>/dev/null
fi

# ─── 4. Tunnel health check (any target reachable = healthy) ───
health_ok=false
for target in "${HEALTH_TARGETS[@]}"; do
    if ping -I "$TUNNEL_NAME" -c 1 -W 3 "$target" >/dev/null 2>&1; then
        health_ok=true
        break
    fi
done

if $health_ok; then
    # ── Tunnel is HEALTHY ──
    PREV_FAILS=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
    echo 0 > "${FAIL_COUNT_FILE}.tmp" && mv "${FAIL_COUNT_FILE}.tmp" "$FAIL_COUNT_FILE"

    # Restore default route if it was removed during failover
    if ! ip route show default | grep -q "$TUNNEL_NAME"; then
        log "tunnel recovered, restoring default route via $TUNNEL_NAME"
        # Remove WAN2 failover route from main table before restoring tun4
        ip route del default via "$(ip route show default 2>/dev/null | awk '/via/{print $3}')" 2>/dev/null
        ip route replace default dev "$TUNNEL_NAME"
        log "WAN2 failover: deactivated, $TUNNEL_NAME is primary again"
    fi

    [[ "$PREV_FAILS" -ge "$FAIL_THRESHOLD" ]] && log "tunnel recovered after $PREV_FAILS failures"
else
    # ── Tunnel is UNHEALTHY ──
    FAILS=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
    FAILS=$((FAILS + 1))
    echo "$FAILS" > "${FAIL_COUNT_FILE}.tmp" && mv "${FAIL_COUNT_FILE}.tmp" "$FAIL_COUNT_FILE"

    if [[ $FAILS -ge $FAIL_THRESHOLD ]]; then
        # Remove tun4 default route if present
        ip route del default dev "$TUNNEL_NAME" 2>/dev/null

        # Ensure WAN2 failover route exists (covers both fresh failover and
        # the case where tun4 was rebuilt but unhealthy with no default route)
        if ! ip route show default | grep -q "via"; then
            WAN2_GW=$(ip route show table 202.eth6 default 2>/dev/null | awk '{print $3}')
            WAN2_DEV=$(ip route show table 202.eth6 default 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev")print $(i+1)}')
            if [[ -n "$WAN2_GW" && -n "$WAN2_DEV" ]]; then
                ip route add default via "$WAN2_GW" dev "$WAN2_DEV" 2>/dev/null
                log "WAN2 failover: activated default via $WAN2_GW dev $WAN2_DEV"
            else
                log "WAN2 failover: WARNING - no WAN2 gateway found in table 202.eth6"
            fi
        fi
    else
        log "tunnel health check failed ($FAILS/$FAIL_THRESHOLD)"
    fi
fi

# ─── 5. Firewall rules (idempotent) ───
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

# ─── 6. WAN status hack: route ip6tnl1 health checks through tunnel ───
ip rule show | grep -q "from $DSLITE_SRC lookup main" || {
    ip rule add from "$DSLITE_SRC" lookup main prio 100
    log "WAN hack: added ip rule for $DSLITE_SRC"
}
ipt_add -t nat -C POSTROUTING -s "$DSLITE_SRC" -o "$TUNNEL_NAME" -j SNAT --to-source "$IPV4_ADDR" || {
    ipt_add -t nat -A POSTROUTING -s "$DSLITE_SRC" -o "$TUNNEL_NAME" -j SNAT --to-source "$IPV4_ADDR"
    log "WAN hack: added SNAT rule for $DSLITE_SRC"
}

# ─── 7. Port forwarding rules (from config, idempotent) ───
for rule in "${PORT_FORWARDS[@]}"; do
    IFS=: read -r proto ext_port dest_ip dest_port <<< "$rule"
    # DNAT (external -> internal)
    ipt_add -t nat -C PREROUTING -i "$TUNNEL_NAME" -p "$proto" --dport "$ext_port" -j DNAT --to-destination "${dest_ip}:${dest_port}" || \
        ipt_add -t nat -A PREROUTING -i "$TUNNEL_NAME" -p "$proto" --dport "$ext_port" -j DNAT --to-destination "${dest_ip}:${dest_port}"
    # FORWARD allow for new connections
    ipt_add -C FORWARD -i "$TUNNEL_NAME" -o br0 -p "$proto" --dport "$dest_port" -d "$dest_ip" -m state --state NEW -j ACCEPT || \
        ipt_add -A FORWARD -i "$TUNNEL_NAME" -o br0 -p "$proto" --dport "$dest_port" -d "$dest_ip" -m state --state NEW -j ACCEPT
    # Hairpin NAT: LAN access via public IP
    ipt_add -t nat -C PREROUTING -i br0 -p "$proto" --dport "$ext_port" -d "$IPV4_ADDR" -j DNAT --to-destination "${dest_ip}:${dest_port}" || \
        ipt_add -t nat -A PREROUTING -i br0 -p "$proto" --dport "$ext_port" -d "$IPV4_ADDR" -j DNAT --to-destination "${dest_ip}:${dest_port}"
    ipt_add -t nat -C POSTROUTING -s "$LAN_SUBNET" -d "$dest_ip" -p "$proto" --dport "$dest_port" -j MASQUERADE || \
        ipt_add -t nat -A POSTROUTING -s "$LAN_SUBNET" -d "$dest_ip" -p "$proto" --dport "$dest_port" -j MASQUERADE
done
