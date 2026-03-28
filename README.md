# UCG-Fiber IPIP6 隧道配置

SoftBank 10G 光纤 + UCG-Fiber 路由器上的 IPIP6 隧道完整配置方案。

## 网络拓扑

```
互联网 ← IPIP6 隧道 (tun4) ← UCG-Fiber ← br0 ← 内网设备
         ↑                      ↑
         公网 IP               eth4 (IPoE IPv6)
         126.2xx.2xx.xx        2400:2411:xxxx:xxxx:xx:xxxx:xxxx:x
```

## 文件清单

| 文件 | 部署位置 | 用途 |
|------|---------|------|
| `tunnel.conf` | `/data/` | 共享配置文件 (IP地址、端口转发等) |
| `tunnel-watchdog.sh` | `/data/` | 隧道维护主脚本 (每15秒执行) |
| `tunnel-teardown.sh` | `/data/` | 一键停止隧道并清理所有规则 |
| `hook_bindtodevice.so` | `/data/` | LD_PRELOAD shim, 让 WAN 健康检查走 tun4 |
| `hook_bindtodevice.c` | (源码) | shim 源码, 用 `zig cc` 交叉编译 |
| `tunnel-watchdog.service` | `/data/` + `/etc/systemd/system/` | watchdog systemd 服务 |
| `tunnel-watchdog.timer` | `/data/` + `/etc/systemd/system/` | watchdog 15秒定时器 |
| `wan-hook.conf` | `/data/` + `/etc/systemd/system/udapi-server.service.d/` | 注入 LD_PRELOAD 到 udapi-server |
| `10-tunnel-setup.sh` | `/data/on_boot.d/` | 固件更新后自动恢复配置 |
| `deploy.sh` | (本地) | 一键部署脚本 |

## 配置文件

所有网络参数集中在 `tunnel.conf` 中管理:

```bash
# 隧道参数
TUNNEL_SRC="<your-ipv6-address>"      # IPoE で取得した IPv6 アドレス
TUNNEL_DST="<tunnel-endpoint-ipv6>"   # トンネル事業者の IPv6 エンドポイント
IPV4_ADDR="<your-public-ipv4>"        # トンネルで割り当てられた固定 IPv4
MTU=1460

# 端口転送 (形式: "プロトコル:外部ポート:内部IP:内部ポート")
PORT_FORWARDS=(
    "tcp:443:192.168.1.100:443"
    "tcp:25565:192.168.1.200:25565"
)
```

添加/删除端口转发只需修改 `tunnel.conf` 中的 `PORT_FORWARDS` 数组，watchdog 和 teardown 会自动适配。

## 功能列表

### 1. IPIP6 隧道 (tunnel-watchdog.sh)
- 自动创建/恢复 IPv4-in-IPv6 隧道 (tun4)
- 防火墙规则: MASQUERADE, FORWARD, MSS clamping, INPUT 保护
- UniFi reprovisioning 后自动恢复
- 单实例锁 (flock) 防止并发执行
- 隧道创建失败时正确报错退出 (不会误报成功)
- 日志自动轮转 (超过 1MB 归档)

### 2. 端口转发 (配置驱动)

端口转发规则从 `tunnel.conf` 读取，每条规则自动包含:
- 外网入站 DNAT (tun4 → br0)
- FORWARD 放行规则
- Hairpin NAT (内网通过公网 IP 访问)

### 3. 隧道健康检查 & WAN2 故障切换
- 每 15 秒检查隧道连通性 (支持多个目标: 8.8.8.8, 1.1.1.1)
- 连续 3 次失败 (45秒) → 删除 tun4 默认路由，启用 WAN2 failover
- 隧道恢复 → 自动恢复 tun4 默认路由, 删除 WAN2 failover 规则
- 失败计数原子写入，防止数据损坏

### 4. WAN 状态 Hack (hook_bindtodevice.so)
- 问题: UniFi 的 `ubios-udapi-server` 用 `SO_BINDTODEVICE("ip6tnl1")` 做 WAN 健康检查, ip6tnl1 (DS-Lite) 不通所以 WAN 显示 DOWN
- 方案: LD_PRELOAD hook 拦截 `setsockopt(SO_BINDTODEVICE)`, 当设备名为 `ip6tnl1` 时替换为 `tun4`
- 效果: 健康检查走 tun4, WAN 显示 UP, tun4 挂了则正确显示 DOWN

### 5. 固件更新自动恢复
- Systemd 单元和 wan-hook.conf 同时备份到 `/data/` (固件更新不会清除)
- `/data/on_boot.d/10-tunnel-setup.sh` 在每次启动时自动恢复配置
- 无需手动干预

## 一键部署

```bash
chmod +x deploy.sh
./deploy.sh ucg
```

## 手动部署

```bash
# 1. 上传文件
scp tunnel.conf tunnel-watchdog.sh tunnel-teardown.sh hook_bindtodevice.so ucg:/data/
ssh ucg 'chmod +x /data/tunnel-watchdog.sh /data/tunnel-teardown.sh'

# 2. 安装 watchdog timer (同时备份 systemd 单元到 /data/)
scp tunnel-watchdog.service tunnel-watchdog.timer ucg:/data/
ssh ucg 'cp /data/tunnel-watchdog.service /data/tunnel-watchdog.timer /etc/systemd/system/'
ssh ucg 'systemctl daemon-reload && systemctl enable --now tunnel-watchdog.timer'

# 3. 安装 WAN hook
scp wan-hook.conf ucg:/data/
ssh ucg 'mkdir -p /etc/systemd/system/udapi-server.service.d'
ssh ucg 'cp /data/wan-hook.conf /etc/systemd/system/udapi-server.service.d/'
ssh ucg 'systemctl daemon-reload && systemctl restart udapi-server'

# 4. 安装 on_boot.d 自动恢复
scp 10-tunnel-setup.sh ucg:/data/
ssh ucg 'mkdir -p /data/on_boot.d && cp /data/10-tunnel-setup.sh /data/on_boot.d/ && chmod +x /data/on_boot.d/10-tunnel-setup.sh'

# 5. 首次运行
ssh ucg 'bash /data/tunnel-watchdog.sh'
```

## 停止/恢复

```bash
# 停止隧道 (清理所有规则, 恢复路由器原始状态)
ssh ucg 'bash /data/tunnel-teardown.sh'

# 重新启用
ssh ucg 'systemctl enable --now tunnel-watchdog.timer && bash /data/tunnel-watchdog.sh'
```

## 移除 WAN Hook

```bash
ssh ucg 'rm /etc/systemd/system/udapi-server.service.d/wan-hook.conf && systemctl daemon-reload && systemctl restart udapi-server'
```

## 重新编译 Hook (固件更新后可能需要)

```bash
# 需要 zig (brew install zig)
zig cc -target aarch64-linux-gnu -shared -fPIC -o hook_bindtodevice.so hook_bindtodevice.c
scp hook_bindtodevice.so ucg:/data/
ssh ucg 'systemctl restart udapi-server'
```

## 自定义端口转发

编辑 `tunnel.conf` 中的 `PORT_FORWARDS` 数组:

```bash
PORT_FORWARDS=(
    "tcp:443:192.168.1.100:443"
    "tcp:25565:192.168.1.200:25565"
    "tcp:8080:192.168.1.150:8080"    # 新增: HTTP 服务
    "udp:51820:192.168.1.150:51820"  # 新增: WireGuard
)
```

修改后重新部署 (`./deploy.sh ucg`) 或直接 `scp tunnel.conf ucg:/data/`，watchdog 下次运行时会自动应用新规则。

## 注意事项

- **固件更新**: `/data/on_boot.d/10-tunnel-setup.sh` 会自动恢复 systemd 配置。如果 `on_boot.d` 机制不工作，手动运行 `./deploy.sh ucg` 即可
- **MTU**: 隧道 MTU 1460, 内网设备保持默认 1500 即可, MSS clamping 自动处理
- **DNS**: 路由器使用 127.0.0.1:53 (dnsmasq), 不受隧道影响
- **IPv6**: 内网 IPv6 通过 eth4 原生 IPoE, 不走隧道
- **并发安全**: watchdog 使用 flock 锁, 手动执行和 timer 不会冲突
- **日志**: 自动轮转, 最大 1MB, 保留一个 `.old` 备份
