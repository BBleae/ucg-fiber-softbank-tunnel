#!/bin/bash
# 10-tunnel-setup.sh — 开机自动恢复隧道配置 (固件更新后)
# 部署位置: /data/on_boot.d/10-tunnel-setup.sh
#
# UniFi 固件更新会清除 /etc/systemd/system/ 下的文件,
# 此脚本在每次启动时从 /data/ 恢复 systemd 单元和 WAN hook.

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
