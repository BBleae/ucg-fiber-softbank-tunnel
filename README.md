# UCG-Fiber：SoftBank 光 10G 的固定 IPv4（UniFi 原生 IPIP）

## 日本語概要

**課題**：SoftBank 光 10G（VNE：BBIX）の固定 IPv4 を、UniFi Cloud Gateway Fiber の標準機能（IPv4 over IPv6／IPIP）で使うと、トンネルが作られない、または設定変更のたびに IPv4 通信が止まる。

**原因**：
- トンネルの送信元アドレスに、BR が受け付ける「委任プレフィックス＋IID」ではなく、WAN 側の DHCPv6 アドレスが使われる。
- 正しいアドレスを手動で追加しても、udapi が管理対象インターフェースから削除する。lo に追加した場合、コントローラーが設定を配信するたびに約 13 秒通信が途切れた。
- プロビジョニングに失敗すると、WAN の IPv6 アドレスが変わるまで再試行されない。

**対策**：監視スクリプト `ipip-guard` を systemd timer で 15 秒ごとに実行し、トンネルの送信元アドレスを修正する。アドレスは udapi の管理外のダミーインターフェースに置き、失敗時はプロビジョニングを再実行する。旧方式からの切り替えには、30 分後の自動ロールバックを付けた。

**結果**：設定を 2 回続けて配信しても ping 300/300 で途切れなかった。再起動後は約 25 秒で自動的に復旧する。

以下、詳細は中国語です。

WAN1 的 IPv4 由 UniFi 自己的 IPIP WAN 承载。本仓库只补 UniFi 在这条线路上的几个缺陷（`ipip-guard`），并保留旧的自建 tun4 方案用于回滚（[`legacy/`](legacy/README.md)）。

## 架构

```
内网 ── br0 ── UCG-Fiber ══ ip6tnl1（IPv4 over IPv6，UniFi 原生）══ BR ── IPv4 互联网
                  │
                 eth4: SoftBank / BBIX IPv6 IPoE（DHCPv6 + PD /56）── IPv6 互联网
                 eth6: WAN2（Starlink），failover
```

- 隧道 `ip6tnl1` 由 udapi 创建，MTU 1452，MSS clamp 1412，走路由表 `201.ip6tnl1`。
- WAN 健康检测（SLA）、failover、端口转发、hairpin 都由 UniFi 自己处理，不再需要自建规则。
- 内网 IPv6 走 eth4 原生 IPoE，不经过隧道。

## UniFi 设置

线路是 SoftBank 光 10G，VNE 是 BBIX，不是 transix。UI 里的「Transix」选项只是用来下发隧道参数（IID、BR、固定 IPv4），在 BBIX 上实测可用。

WAN1：**IPv4 连接 → IPv4 over IPv6 → IPIP → Transix**；IPv6 连接用 DHCPv6，PD /56。

| 字段（控制器里的 key） | 填写 |
|---|---|
| 用户名 `wan_ipip_username` | 占位值，例如 `u0000000000` |
| 密码 `x_wan_ipip_password` | 占位值 |
| IPv6 接口标识 `wan_ipip_ipv6_identifier` | 固定 IP 开通通知里的 interface ID，形如 `::xx:xxxx:xxxx:0` |
| IPv6 网关 `wan_ipip_ipv6_gateway` | BR 的 IPv6 地址 |
| IPv4 地址 `wan_ip` | 固定 IPv4 |
| 子网掩码 `wan_netmask` | `255.255.255.255` |

用户名和密码会随「地址更新」请求一起发出去。ipip-guard 已把这个请求改到 Cloudflare 的 trace 页面，所以这里不要填真实凭据。

## ipip-guard 补的缺陷

`/data/ipip-guard.sh` 由 `ipip-guard.timer` 每 15 秒运行一次，用 flock 防止重复运行，日志在 `/var/log/ipip-guard.log`。

1. **地址更新**：Transix 选项下发隧道参数前，要先请求一次「地址更新」URL，而且必须拿到 HTTP 响应。守护脚本写入覆盖文件 `/data/udapi-config/internet_multifeed.eth4.address_update`，把 URL 换成一个必定有响应的地址。
2. **隧道本地地址**：BR 只接受「委派前缀 + IID」这个源地址，ubnt-hb46pp 也算对了，见 `/run/hb46pp/eth4.json` 里的 `ip6tnl_parameters`。但 udapi 建隧道时用的是 eth4 自己的 DHCPv6 地址。守护脚本按 hb46pp 的结果改正隧道的 local，并把这个地址挂到 dummy 网卡 `ipipsrc0` 上。
3. **provisioning 不重试**：ubnt-hb46pp 失败后，要等 eth4 的 IPv6 地址变化才会再试。已经配置了 IPIP 但隧道 60 秒还没出现时，守护脚本会补跑一次 `ubnt-hb46pp ... -1`，两次之间至少隔 5 分钟。

**为什么挂在 dummy 网卡上**：udapi 会删掉它所管理接口上它不认识的地址。eth4 上的会在每次 DHCPv6 更新时被删；lo 上的会在每次控制器下发配置时被删，UI 里的任何改动都会触发，包括加一条端口转发。地址一旦缺失，内核就会报 `ip6tnl1 xmit: Local address not yet configured!`，并停止发包。挂在 lo 上时实测会断 13 秒。`ipipsrc0` 不归 udapi 管：改用它之后连续下发两次配置，ping 300/300，没有新的报错。

## 部署

```bash
./deploy.sh ucg
```

脚本会上传文件、安装并启用 timer、运行一次守护。重复执行没有副作用，固件更新后也可以直接重跑，用来恢复 `/etc/systemd/system` 下的单元。如果路由器上还在跑 tun4，它只上传文件，不安装 timer。

## 从 tun4 迁移（一次性）

1. 运行 `./deploy.sh ucg`，把文件上传到 `/data/`。
2. 在路由器上执行 `systemd-run --unit=ipip-cutover --collect /bin/bash /data/native-ipip-cutover.sh prepare`。它会依次：
   - 快照当前状态，存到 `/data/ipip-cutover/<时间>/`；
   - 武装 30 分钟的自动回滚；
   - 拆掉 tun4；
   - 移除 LD_PRELOAD hook，然后重启 udapi；
   - 安装 ipip-guard。

   这一步期间，内网 IPv4 暂时走 WAN2。任何一步失败都会立即回滚。
3. 按上面的表格在 UI 里把 WAN1 的 IPv4 改成 IPIP。守护脚本会自动修正隧道，大约需要 30 秒。
4. 确认正常后，执行 `bash /data/native-ipip-cutover.sh commit`，取消自动回滚。

## 回滚到 tun4

1. 在 UI 里把 WAN1 的 IPv4 改回切换前的设置，可以在切换快照的 `network_conf-wan.json` 里查到。原生隧道和 tun4 的两端地址相同，内核不允许两者同时存在，所以这一步必须先做。
2. 执行 `bash /data/native-ipip-rollback.sh --now`。它会停掉守护、删除 `ipipsrc0`，并恢复 hook、开机脚本和 watchdog。

回滚依赖路由器 `/data/` 下保留的旧方案文件。在全新的路由器上回滚，要先用 `legacy/deploy.sh` 部署旧方案。

## 端口转发

在 UniFi UI 的端口转发里配置，接口选 WAN1。生成的 DNAT 匹配 ipset `UBIOS_KEY_ADDRv4_ip6tnl1`，hairpin 也能用。旧方案中 `tunnel.conf` 的 `PORT_FORWARDS` 已不再使用。

## 检查

```bash
ip -d link show ip6tnl1            # local 应该是「前缀 + IID」，不是 eth4 自己的地址
ip -6 addr show dev ipipsrc0       # 同一个地址挂在这里
tail /var/log/ipip-guard.log
dmesg | grep 'not yet configured'  # 有新增说明隧道源地址曾经缺失
ip -6 rule; ip route show table 201.ip6tnl1
```

## 注意事项

- **重启 / udapi 重启**：udapi 会用错误的 local 重建隧道，守护脚本大约 25 秒内改正，这期间 IPv4 不通。
- **固件更新**：`/etc/systemd/system` 下的单元可能丢失。检查 `ipip-guard.timer`，不在了就重跑 `./deploy.sh ucg`。如果新固件修好了隧道 local 的问题，守护脚本什么也不会做。
- **测外网方向**：不能从路由器自己经 WAN2 访问固定 IP，因为回包的源地址是本机地址，会被当作 martian 丢掉。要用真正的外部网络，比如手机蜂窝网络。
- **ECM/NSS offload**：改正隧道 local 后，守护脚本会写 `/sys/kernel/debug/ecm/ecm_db/defunct_all`，让已加速的连接重新建立。

## 文件

| 文件 | 部署位置 | 用途 |
|---|---|---|
| `ipip-guard.sh` | `/data/` | 守护脚本 |
| `ipip-guard.service` / `.timer` | `/data/` + `/etc/systemd/system/` | 每 15 秒运行一次 |
| `native-ipip-cutover.sh` | `/data/` | 从 tun4 切换到原生 IPIP（prepare / commit） |
| `native-ipip-rollback.sh` | `/data/` | 回滚到 tun4 |
| `deploy.sh` | 本地 | 一键部署 |
| `legacy/` | — | 旧的自建 tun4 方案，仅用于回滚 |
