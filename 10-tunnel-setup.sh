#!/bin/bash
# 10-tunnel-setup.sh — 有 on_boot.d 执行器时恢复隧道配置
# 部署位置: /data/on_boot.d/10-tunnel-setup.sh
#
# 此脚本仅在安装 /data/on_boot.d 执行器（例如 udm-boot.service）后运行。
# 运行时从 /data/ 恢复 systemd 单元和 WAN hook。

DATA_DIR="/data"

# 恢复 systemd 单元 (从 /data/ 备份)
cp "$DATA_DIR/tunnel-watchdog.service" /etc/systemd/system/ 2>/dev/null
cp "$DATA_DIR/tunnel-watchdog.timer" /etc/systemd/system/ 2>/dev/null

# 恢复 WAN hook
mkdir -p /etc/systemd/system/udapi-server.service.d
cp "$DATA_DIR/wan-hook.conf" /etc/systemd/system/udapi-server.service.d/ 2>/dev/null

# 重新加载并启用
systemctl daemon-reload
systemctl enable --now tunnel-watchdog.timer
systemctl restart udapi-server

echo "$(date): tunnel configuration restored by on_boot.d" >> /var/log/tunnel-watchdog.log
# Pin only the source address during early boot. The timer will build routes
# and test the tunnel after network-online, when the eth4 RA route is ready.
if [[ -r "$DATA_DIR/tunnel.conf" ]] && source "$DATA_DIR/tunnel.conf" && [[ -n "${TUNNEL_SRC:-}" ]]; then
    if ! ip -6 addr show dev lo to "${TUNNEL_SRC}/128" | grep -q 'inet6'; then
        if ! ip -6 addr add "${TUNNEL_SRC}/128" dev lo 2>/dev/null; then
            if ! ip -6 addr show dev lo to "${TUNNEL_SRC}/128" | grep -q 'inet6'; then
                echo "$(date): ERROR: failed to pin tunnel source IPv6 on lo during boot" >> /var/log/tunnel-watchdog.log
            fi
        fi
    fi
else
    echo "$(date): ERROR: cannot load tunnel source IPv6 during boot" >> /var/log/tunnel-watchdog.log
fi
