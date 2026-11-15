#!/bin/bash
# ipip-guard 一键部署 (UniFi 原生 IPIP WAN 的守护)
# 用法: ./deploy.sh <router-host>
# 例如: ./deploy.sh ucg
#
# 可重复执行: 固件更新后 /etc/systemd/system 下的单元可能丢失，重新运行即可恢复。
# 不改 UniFi 的 WAN 配置: WAN1 的 IPv4 要在 UI 里设成 IPIP (见 README)。
# 路由器上还在跑旧的 tun4 方案时只上传文件，切换请按 README 用 native-ipip-cutover.sh。

set -euo pipefail

HOST="${1:?用法: ./deploy.sh <router-host>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
FILES=(ipip-guard.sh ipip-guard.service ipip-guard.timer native-ipip-cutover.sh native-ipip-rollback.sh)

echo "=== ipip-guard 部署 → $HOST ==="

echo "[1/3] 上传文件到 /data/ ..."
scp "${FILES[@]/#/$DIR/}" "$HOST:/data/"
ssh "$HOST" "chmod +x /data/ipip-guard.sh /data/native-ipip-cutover.sh /data/native-ipip-rollback.sh"

if ssh "$HOST" "ip link show tun4 > /dev/null 2>&1 || systemctl is-active --quiet tunnel-watchdog.timer"; then
    echo ""
    echo "路由器上还在运行旧的 tun4 方案，文件已上传，未安装 timer。"
    echo "切换步骤见 README 的「从 tun4 迁移」。"
    exit 0
fi

echo "[2/3] 安装并启用 ipip-guard.timer ..."
ssh "$HOST" "cp /data/ipip-guard.service /data/ipip-guard.timer /etc/systemd/system/ \
    && systemctl daemon-reload && systemctl enable --now ipip-guard.timer"

echo "[3/3] 运行一次并检查 ..."
ssh "$HOST" "bash /data/ipip-guard.sh; tail -5 /var/log/ipip-guard.log 2>/dev/null; \
    ping -c 2 -W 3 1.1.1.1 > /dev/null && echo 'IPv4 连通: OK' || echo 'IPv4 连通: FAIL'"

echo ""
echo "=== 完成 ==="
echo "  日志:  ssh $HOST 'tail -20 /var/log/ipip-guard.log'"
echo "  隧道:  ssh $HOST 'ip -d link show type ip6tnl; ip -6 addr show dev ipipsrc0'"
