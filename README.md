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
| `10-tunnel-setup.sh` | `/data/on_boot.d/` | 有 `udm-boot.service` 时在开机恢复配置 |
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
- 将隧道源 IPv6 同时保留在 `lo`，避免 eth4 被 WAN 管理进程清理地址时中断 tun4
- 隧道外层包固定走 eth4：tun4 的 fwmark 设为 UniFi 的 WAN1 路由 mark（从 `ip -6 rule` 动态读取），并在 ip6tables mangle OUTPUT 第 1 条放行外层包，避开 UniFi 的 mark 链
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

### 5. 启动恢复
- 已启用的 `tunnel-watchdog.timer` 在普通重启后恢复隧道并将源 IPv6 加到 `lo`
- Systemd 单元和 wan-hook.conf 同时备份到 `/data/`
- `/data/on_boot.d/10-tunnel-setup.sh` 只有安装并启用 `udm-boot.service` 等执行器后才会运行；该脚本会先恢复单元，再将源地址加到 `lo`
- 当前 UCG-Fiber 的 UniFi OS 6.0.17 没有 `udm-boot.service`，下一次固件更新后须确认 timer 和 WAN hook 仍在运行

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

# 4. 放置可选的 on_boot.d 恢复脚本（需另有执行器）
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
    "tcp:47000-49000:192.168.1.150:47000-49000"  # 新增: 端口范围
    "udp:47000-49000:192.168.1.150:47000-49000"
)
```

端口范围写成 `起-止` (含两端)，内外网范围必须相同，按原端口一一映射 (DNAT 不指定端口，内核不改写端口)。范围格式错误 (非 `起-止`、起 > 止、超过 65535) 或两侧不一致的规则会被跳过，每条每次开机只记一次日志。

修改后重新部署 (`./deploy.sh ucg`) 或直接 `scp tunnel.conf ucg:/data/`，watchdog 下次运行时会自动应用新规则。

## 注意事项

- **UniFi OS 6.0.17 的 eth4 地址抖动**: 实测 DHCPv4 `leasefail` 约每 30 秒伴随 eth4 上的静态隧道源 IPv6 被删除；`lo` 上保留同一个 `/128` 后，eth4 再次删址时 tun4 仍可通。部署后需从内网设备连续测试至少 5 分钟，并重启验证。运行 `tunnel-teardown.sh` 会移除 `lo` 上的地址。
- **UniFi OS 6.0.17 的隧道外层路由**: UniFi 把 eth6 当作唯一的 IPv6 出口，mangle OUTPUT 会给外层包打上 eth6 mark（`0x21960000`）并据此重新查路由。外层包之所以还能走 eth4，只是因为 main 表里有 watchdog 复制进去的 eth4 IPv6 默认。udapi 每次 DHCPv6 更新（约每 2.85 分钟）都会删掉这条（`Removing unknown route ::/0`），在 watchdog 下一轮补回之前，外层包从 Starlink 发出被丢，每次断 0–15 秒。修复由两部分组成：tun4 设 WAN1 fwmark，让隧道自身查路由时命中 `fwmark ... lookup 201.eth4`；mangle OUTPUT 第 1 条放行外层包（comment `tun4-outer-bypass`），使其 mark 不被改写、不会触发重路由。自建 rule/table 会被 udapi 对账删除，不能用。检查命令: `ip -d link show tun4 | grep fwmark`、`ip6tables -t mangle -S OUTPUT | sed -n 2p`
- **固件更新**: 更新后检查 `tunnel-watchdog.timer`、`udapi-server` 的 WAN hook、`lo` 上的源地址和 tun4 的 fwmark；缺失时运行 `./deploy.sh ucg` 恢复
- **MTU**: 隧道 MTU 1460, 内网设备保持默认 1500 即可, MSS clamping 自动处理
- **DNS**: 路由器使用 127.0.0.1:53 (dnsmasq), 不受隧道影响
- **IPv6**: 内网 IPv6 通过 eth4 原生 IPoE, 不走隧道
- **并发安全**: watchdog 使用 flock 锁, 手动执行和 timer 不会冲突
- **日志**: 自动轮转, 最大 1MB, 保留一个 `.old` 备份
