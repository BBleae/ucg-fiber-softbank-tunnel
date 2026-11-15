#!/bin/bash
# UCG-Fiber IPIP6 隧道一键部署脚本
# 用法: ./deploy.sh <router-host>
# 例如: ./deploy.sh ucg
#
# 前提条件:
#   1. 路由器已通过 SSH 可达 (ssh <router-host> 能登录)
#   2. 路由器 WAN 设置中 IPv4 配置为 DS-Lite
#   3. 路由器已有 IPv6 IPoE 连接 (SoftBank 10G)

set -euo pipefail

HOST="${1:?用法: ./deploy.sh <router-host>}"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== UCG-Fiber IPIP6 隧道部署 ==="
echo "目标: $HOST"
echo ""

# 1. 上传脚本和配置到 /data/
echo "[1/6] 上传文件到 /data/ ..."
scp "$DIR/tunnel.conf" "$HOST:/data/"
scp "$DIR/tunnel-watchdog.sh" "$HOST:/data/"
scp "$DIR/tunnel-teardown.sh" "$HOST:/data/"
scp "$DIR/hook_bindtodevice.so" "$HOST:/data/"
echo "  文件上传完成"

# 2. 设置权限
echo "[2/6] 设置权限..."
ssh "$HOST" "chmod +x /data/tunnel-watchdog.sh /data/tunnel-teardown.sh"
echo "  权限设置完成"

# 3. 安装 systemd 服务 (同时备份到 /data/ 以便 on_boot.d 恢复)
echo "[3/6] 安装 watchdog systemd 服务..."
scp "$DIR/tunnel-watchdog.service" "$HOST:/data/"
scp "$DIR/tunnel-watchdog.timer" "$HOST:/data/"
ssh "$HOST" "cp /data/tunnel-watchdog.service /etc/systemd/system/ && cp /data/tunnel-watchdog.timer /etc/systemd/system/"
ssh "$HOST" "systemctl daemon-reload && systemctl enable --now tunnel-watchdog.timer"
echo "  watchdog timer 已启用"

# 4. 安装 LD_PRELOAD hook (WAN 状态 hack)
echo "[4/6] 安装 WAN 状态 hook..."
scp "$DIR/wan-hook.conf" "$HOST:/data/"
ssh "$HOST" "mkdir -p /etc/systemd/system/udapi-server.service.d"
ssh "$HOST" "cp /data/wan-hook.conf /etc/systemd/system/udapi-server.service.d/"
ssh "$HOST" "systemctl daemon-reload && systemctl restart udapi-server"
echo "  WAN hook 已安装并重启 udapi-server"

# 5. 安装 on_boot.d 自动恢复脚本 (固件更新后自动恢复)
echo "[5/6] 安装 on_boot.d 自动恢复..."
scp "$DIR/10-tunnel-setup.sh" "$HOST:/data/"
ssh "$HOST" "mkdir -p /data/on_boot.d && cp /data/10-tunnel-setup.sh /data/on_boot.d/ && chmod +x /data/on_boot.d/10-tunnel-setup.sh"
echo "  on_boot.d 脚本已安装"

# 6. 首次运行 watchdog
echo "[6/6] 首次运行 watchdog..."
ssh "$HOST" "bash /data/tunnel-watchdog.sh"
echo "  隧道已建立"

# 验证
echo ""
echo "=== 验证 ==="
ssh "$HOST" "ping -c 2 -W 3 8.8.8.8 && echo '网络连通: OK' || echo '网络连通: FAIL'"
echo ""
echo "=== 部署完成 ==="
echo ""
echo "常用命令:"
echo "  查看日志:    ssh $HOST 'tail -20 /var/log/tunnel-watchdog.log'"
echo "  停止隧道:    ssh $HOST 'bash /data/tunnel-teardown.sh'"
echo "  重新启用:    ssh $HOST 'systemctl enable --now tunnel-watchdog.timer && bash /data/tunnel-watchdog.sh'"
echo "  移除 hook:   ssh $HOST 'rm /etc/systemd/system/udapi-server.service.d/wan-hook.conf && systemctl daemon-reload && systemctl restart udapi-server'"
