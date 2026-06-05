# WireGuard 家宽出口脚本

这个仓库包含以下脚本：

- `setup-home-vps.sh`：家宽 VPS 出口端，配置 WireGuard 服务端、NAT、DNS 与基础过滤规则。
- `setup-normal-vps.sh`：普通 VPS 客户端，将 IPv4 出口切到家宽 VPS，并保留 SSH 连接。
- `setup-home-socks5.sh`：家宽 VPS SOCKS5 服务端，创建账号密码并输出可复制的 SOCKS5 地址。
- `setup-home-ss.sh`：家宽 VPS Shadowsocks 服务端，适合 SOCKS5 被线路 reset 时使用。
- `setup-home-firewall-whitelist.sh`：家宽入口 IP 白名单防护，只允许普通机器 IP 访问家宽入口端口，其他来源 DROP。
- `setup-egress-socks.sh`：普通机器客户端，将节点和 Incus 小鸡出口切到上游 SOCKS5 或 Shadowsocks。
- `setup-gre-gateway.sh`：优化线路节点 GRE 网关，负责小鸡公网入口、DNAT 和出口 SNAT。
- `setup-gre-backend.sh`：普通 Incus 节点 GRE 后端，让小鸡流量走优化线路网关。
- `setup-wg-gateway.sh`：优化线路节点 WireGuard 网关，替代 GRE，适合 GRE 导致 HTTPS/TLS 卡住的线路。
- `setup-wg-backend.sh`：普通 Incus 节点 WireGuard 后端，让小鸡通过 WG 走优化线路网关。
- `setup-ab-entry.sh`：三机 AB 隧道 A 入口机，用户访问 A，流量经 A-B WireGuard 隧道进入 B。
- `setup-ab-relay.sh`：三机 AB 隧道 B 中继机，把 A 隧道来的端口流量转发到 C 小鸡所在机器同端口。
- `diagnose-github-raw.sh`：诊断 `raw.githubusercontent.com`、`Check.Place` 等 HTTPS 连接卡住的问题。

脚本默认面向 Debian/Ubuntu，需要 root 权限执行。

## 一键拉取

```bash
git clone https://github.com/JetSprow/23232.git wg-home-exit
cd wg-home-exit
chmod +x *.sh
```

后续更新：

```bash
cd wg-home-exit
git pull --ff-only
chmod +x *.sh
```

## 交互式一键安装器

不想手动选择单个脚本时，直接运行交互式安装器：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/install.sh -o install.sh
sudo bash install.sh
```

安装器会先安装基础工具 `bash`、`curl`、`ca-certificates`、`git`、`sudo`，然后把脚本同步到 `/opt/23232`，再通过菜单选择家宽出口、SOCKS5/SS、GRE 优化线路、WireGuard 优化线路和 HTTPS 诊断等功能。

如需指定本地脚本目录：

```bash
sudo INSTALL_DIR=/root/23232 bash install.sh
```

## 一键执行

家宽 VPS 出口端：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/setup-home-vps.sh -o setup-home-vps.sh
sudo bash setup-home-vps.sh
```

普通 VPS 客户端：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/setup-normal-vps.sh -o setup-normal-vps.sh
sudo bash setup-normal-vps.sh
```

家宽 VPS SOCKS5 服务端：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/setup-home-socks5.sh -o setup-home-socks5.sh
sudo bash setup-home-socks5.sh
```

家宽入口 IP 白名单防护：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/setup-home-firewall-whitelist.sh -o setup-home-firewall-whitelist.sh
sudo ALLOW_IPS='普通机器公网IP1,普通机器公网IP2' PROTECT_PORTS='51820/udp,6013/tcp,6013/udp' bash setup-home-firewall-whitelist.sh
```

只允许白名单 IP 访问这些入口端口，其他来源直接 DROP。默认不修改 SSH，也不改全局默认策略，避免误锁机器。

如果确认管理入口也只会从普通机器访问，可以开启全入口锁定：

```bash
sudo ALLOW_IPS='普通机器公网IP1,普通机器公网IP2' LOCKDOWN_ALL=1 bash setup-home-firewall-whitelist.sh
```

`LOCKDOWN_ALL=1` 会让所有入站只接受白名单 IP 和已建立连接，使用前务必确认当前 SSH 来源已经在白名单内。

管理：

```bash
sudo home-fw status
sudo home-fw add 新普通机器公网IP
sudo home-fw remove 旧普通机器公网IP
sudo home-fw off
```

如果家宽机器的“出口 IP”和普通机器能连到的“入口 IP/域名”不一致，必须指定入口地址：

```bash
sudo SOCKS_HOST=你的入口IP或域名 SOCKS_PORT=端口 bash setup-home-socks5.sh
```

脚本会输出：

```text
socks5://用户名:密码@地址:端口
```

普通机器接入该 SOCKS5：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/setup-egress-socks.sh -o setup-egress-socks.sh
sudo BUILTIN_PROXY_URL='socks5://用户名:密码@地址:端口' bash setup-egress-socks.sh
```

如果 SOCKS5 远程 TLS 握手被 reset，改用 Shadowsocks：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/setup-home-ss.sh -o setup-home-ss.sh
sudo SS_HOST=你的入口IP或域名 SS_PORT=端口 bash setup-home-ss.sh
```

普通机器接入该 SS：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/setup-egress-socks.sh -o setup-egress-socks.sh
sudo BUILTIN_PROXY_URL='ss://aes-256-gcm:密码@地址:端口' bash setup-egress-socks.sh
```

已安装 `zck` 后切换到新的 SS：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/setup-egress-socks.sh -o setup-egress-socks.sh
sudo bash setup-egress-socks.sh
sudo zck proxy add 'ss://aes-256-gcm:密码@地址:端口'
sudo zck proxy switch
sudo zck restart
sudo zck test
```

已安装后切换上游出口：

```bash
sudo zck proxy add 'socks5://用户名:密码@地址:端口'
sudo zck proxy switch
sudo zck test
```

`zck` 是普通机器客户端脚本安装的管理命令，家宽 SOCKS5 服务端不需要也不会安装该命令。SOCKS5 客户端默认使用普通机器本机 DNS 直连解析，避免 DNS 查询走家宽 SOCKS5 后被重置；实际业务流量仍会走家宽 SOCKS5 出口。

## Shadowsocks 模式

当 SOCKS5 服务端本机测试正常，但普通机器远程连接后 HTTPS/TLS 一直 `Connection reset by peer`，优先使用 Shadowsocks 模式。

1. 家宽机器运行：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/setup-home-ss.sh -o setup-home-ss.sh
sudo SS_HOST=你的入口IP或域名 SS_PORT=端口 bash setup-home-ss.sh
```

2. 复制输出的 `ss://...`。

3. 普通机器运行：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/setup-egress-socks.sh -o setup-egress-socks.sh
sudo BUILTIN_PROXY_URL='ss://aes-256-gcm:密码@地址:端口' bash setup-egress-socks.sh
sudo zck test
```

4. 查看和切换上游：

```bash
sudo zck proxy list
sudo zck proxy add 'ss://aes-256-gcm:密码@地址:端口'
sudo zck proxy switch
sudo zck restart
sudo zck test
```

## 自动化运维和自修复

除 `diagnose-github-raw.sh` 这种一次性诊断脚本外，安装型脚本都会写入 systemd 服务、定时检查器和快捷管理命令。重启机器后会自动恢复；服务、路由、防火墙、MSS、预转发等关键规则丢失时会自动补回。

家宽 WireGuard 出口：

```bash
sudo wg-home status
sudo wg-home check
sudo wg-home restart
sudo wg-home logs -n 80
```

普通 WireGuard 客户端：

```bash
sudo wg-normal status
sudo wg-normal check
sudo wg-normal recover
sudo wg-normal fallback
sudo wg-normal restart
sudo wg-normal stop
sudo wg-normal logs -n 80
```

普通 WireGuard 客户端会优先使用家宽出口；如果家宽端 WireGuard 握手失效、动态 IP 未恢复、或真实 IPv4 出口测试不通，会自动撤销策略路由并回落到普通 VPS 本机原出口，避免整机断网。回落后 `wg-normal-check.timer` 每 5 分钟尝试一次家宽出口，恢复成功后再切回。

家宽 SOCKS5 / Shadowsocks：

```bash
sudo home-socks5 status
sudo home-socks5 restart
sudo home-socks5 logs -n 80

sudo home-ss status
sudo home-ss restart
sudo home-ss logs -n 80
```

普通机器代理出口：

```bash
sudo zck status
sudo zck repair
sudo zck recover
sudo zck fallback
sudo zck restart
sudo zck diag
```

普通机器 SOCKS5 / Shadowsocks 代理出口同样带回落保护：上游代理出口不通时会停掉 sing-box/TUN 并恢复本机原出口，但保留自修复定时器；之后每 5 分钟自动尝试恢复代理出口。

GRE / WireGuard 优化线路：

```bash
sudo gre-gw status
sudo gre-gw repair
sudo gre-gw restart
sudo gre-gw logs -n 80

sudo gre-be status
sudo gre-be repair
sudo gre-be restart
sudo gre-be logs -n 80

sudo wg-gw status
sudo wg-gw repair
sudo wg-gw restart

sudo wg-be status
sudo wg-be repair
sudo wg-be restart
```

定时器状态：

```bash
systemctl list-timers '*check.timer' --no-pager
```

## 紧急停止方法

这些命令用于先恢复机器可访问性。普通侧脚本会尽量回落到本机原出口；服务端脚本会停止对应服务和自修复定时器。

家宽 WireGuard 服务端：

```bash
sudo systemctl disable --now wg-home-check.timer wg-quick@wg0 dnsmasq
sudo iptables -t nat -D POSTROUTING -s 10.0.0.0/24 ! -d 10.0.0.0/24 -j MASQUERADE 2>/dev/null || true
```

普通 WireGuard 客户端：

```bash
sudo wg-normal stop
```

普通机器 SOCKS5 / Shadowsocks 代理出口：

```bash
sudo zck off
```

家宽 SOCKS5 服务端：

```bash
sudo systemctl disable --now home-socks5-check.timer danted home-socks5-mss.service
```

家宽 Shadowsocks 服务端：

```bash
sudo systemctl disable --now home-ss-check.timer home-ss.service
```

家宽入口 IP 白名单防护：

```bash
sudo home-fw off
```

GRE 优化线路：

```bash
sudo gre-be off
sudo gre-gw off
```

WireGuard 优化线路：

```bash
sudo wg-be off
sudo wg-gw off
```

三机 AB 隧道：

```bash
sudo ab-entry off
sudo ab-relay off
```

如果 helper 命令不存在，可以直接停对应定时器和服务：

```bash
sudo systemctl disable --now '*check.timer'
sudo systemctl stop wg-quick@wg0 sing-box egress-bypass 2>/dev/null || true
```

## GRE 优化线路模式

适合“用户 -> 优化线路节点 -> 普通 Incus 节点小鸡”的模式。小鸡仍创建在普通节点，公网入口和出口都走优化节点。

小鸡网段是普通 Incus 节点现有 `incusbr0` 的 IPv4 网段，不是脚本额外创建的新网段。可在普通节点执行：

```bash
ip -4 addr show incusbr0
```

1. 在优化线路节点运行：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/setup-gre-gateway.sh -o setup-gre-gateway.sh
sudo BACKEND_PUBLIC_IP=普通节点公网IP GUEST_SUBNET=10.10.0.0/22 bash setup-gre-gateway.sh
```

2. 在普通 Incus 节点运行：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/setup-gre-backend.sh -o setup-gre-backend.sh
sudo GATEWAY_PUBLIC_IP=优化节点公网IP GUEST_SUBNET=10.10.0.0/22 bash setup-gre-backend.sh
```

3. 端口转发：

默认已开启整段预转发，优化线路节点会把 `20000-30000` 的 TCP/UDP 入口流量透传到普通 Incus 节点的 GRE IP，端口号保持不变。

也就是说，面板用户创建 `20000-30000` 范围内的端口时，不需要再到优化线路节点手动添加 `gre-gw add`。优化线路节点负责“公网入口 -> 普通节点 GRE IP:同端口”，普通节点原有面板/Incus 端口规则继续负责“端口 -> 小鸡”。

如需修改预转发范围，在两端使用相同的 `PREFORWARD_RANGE`：

```bash
sudo PREFORWARD_RANGE=20000:30000 BACKEND_PUBLIC_IP=普通节点公网IP GUEST_SUBNET=10.10.0.0/22 bash setup-gre-gateway.sh
sudo PREFORWARD_RANGE=20000:30000 GATEWAY_PUBLIC_IP=优化节点公网IP GUEST_SUBNET=10.10.0.0/22 bash setup-gre-backend.sh
```

如需关闭整段预转发：

```bash
sudo PREFORWARD_ENABLE=0 BACKEND_PUBLIC_IP=普通节点公网IP GUEST_SUBNET=10.10.0.0/22 bash setup-gre-gateway.sh
sudo PREFORWARD_ENABLE=0 GATEWAY_PUBLIC_IP=优化节点公网IP GUEST_SUBNET=10.10.0.0/22 bash setup-gre-backend.sh
```

仍然可以在优化线路节点手动添加单端口转发：

```bash
sudo gre-gw add tcp 25022 小鸡IP 22
```

4. 两端一键切换：

优化线路节点：

```bash
sudo gre-gw status
sudo gre-gw off
sudo gre-gw on
sudo gre-gw restart
sudo gre-gw repair
sudo gre-gw logs -n 80
```

普通 Incus 节点：

```bash
sudo gre-be status
sudo gre-be off
sudo gre-be on
sudo gre-be restart
sudo gre-be repair
sudo gre-be logs -n 80
```

注意：每个普通节点的小鸡网段必须唯一，例如 `10.10.0.0/22`、`10.14.0.0/22`、`10.18.0.0/22`，否则优化节点无法正确路由。

GRE 默认使用较保守的 `MTU=1280` 和 TCP `MSS=1240`。如果开启 GRE 后小鸡访问 HTTPS/TLS 报错，而关闭 `gre-be` 后立即正常，优先继续降低 GRE MTU/MSS，并且两端必须使用相同值：

```bash
sudo GRE_MTU=1180 TCP_MSS=1140 BACKEND_PUBLIC_IP=普通节点公网IP GUEST_SUBNET=10.10.0.0/22 bash setup-gre-gateway.sh
sudo GRE_MTU=1180 TCP_MSS=1140 GATEWAY_PUBLIC_IP=优化节点公网IP GUEST_SUBNET=10.10.0.0/22 bash setup-gre-backend.sh
```

测试小鸡 HTTPS：

```bash
incus exec 实例名 -- sh -lc 'apk update || true; wget -O- https://api.ipify.org'
```

## WireGuard 优化线路模式

如果 GRE 开启后小鸡访问 HTTPS/TLS 卡住，而关闭 `gre-be` 后立即恢复，优先改用 WireGuard 优化线路模式。它和 GRE 模式作用相同：小鸡仍创建在普通 Incus 节点，用户入口和小鸡出口走优化线路节点。

1. 在普通 Incus 节点先生成后端公钥：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/setup-wg-backend.sh -o setup-wg-backend.sh
sudo GUEST_SUBNET=10.10.0.0/22 bash setup-wg-backend.sh
```

复制输出的“普通节点 WireGuard 公钥”。

2. 在优化线路节点运行网关脚本，并粘贴普通节点公钥：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/setup-wg-gateway.sh -o setup-wg-gateway.sh
sudo WG_PORT=51820 GUEST_SUBNET=10.10.0.0/22 bash setup-wg-gateway.sh
```

复制输出的“网关地址、网关端口、网关公钥”。

3. 回到普通 Incus 节点完成接入：

```bash
sudo GATEWAY_PUBLIC_IP=优化节点公网IP GATEWAY_PORT=51820 GATEWAY_PUBLIC_KEY='优化节点WG公钥' GUEST_SUBNET=10.10.0.0/22 bash setup-wg-backend.sh
```

4. 管理和测试：

优化线路节点：

```bash
sudo wg-gw status
sudo wg-gw repair
sudo wg-gw restart
sudo wg-gw off
sudo wg-gw on
sudo wg-opt-restart
```

普通 Incus 节点：

```bash
sudo wg-be status
sudo wg-be repair
sudo wg-be restart
sudo wg-be off
sudo wg-be on
sudo wg-opt-restart
incus exec 实例名 -- sh -lc 'apk update || true; wget -O- https://api.ipify.org'
```

WireGuard 模式默认预转发 `20000-30000` 的 TCP/UDP 到普通节点 WG IP，端口号保持不变。面板节点端口范围也应设置为 `20000-30000`，用户访问地址填优化线路节点公网 IP 或域名。

脚本使用 `wg-opt` 作为 WireGuard 接口名，并会安装自修复定时器。普通节点会持续检查 `2020` 路由表、`10.10.0.0/22` 小鸡网段策略路由、`10.255.10.2` 回程策略路由，以及预转发/放行规则；优化线路节点会持续检查到小鸡网段的路由、SNAT、DNAT、FORWARD 和 WireGuard 端口放行规则。规则丢失时会自动补回，不会在正常状态下反复断开 WireGuard。

检查自修复定时器：

```bash
systemctl status wg-backend-check.timer --no-pager -l
systemctl status wg-gateway-check.timer --no-pager -l
```

脚本默认使用 WireGuard `MTU=1180`。如需手动指定：

```bash
sudo WG_MTU=1180 bash setup-wg-backend.sh
sudo WG_MTU=1180 bash setup-wg-gateway.sh
```

诊断 GitHub Raw / Check.Place 卡住：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/diagnose-github-raw.sh -o diagnose-github-raw.sh
sudo bash diagnose-github-raw.sh 2>&1 | tee /tmp/github-raw-diagnose.log
```

## 三机 AB 隧道入口模式

适合你现在这种三台机器：

```text
用户 -> A 入口机公网IP:20000-30000
      -> A-B WireGuard 隧道
      -> B 中继机
      -> C 小鸡所在机器:同端口
      -> C 面板原有端口映射 -> 小鸡
```

C 不需要安装新脚本，继续作为面板节点使用。面板连接 Incus 仍填 C 的 `https://C公网IP:8443`；用户访问地址/节点展示地址填 A 的公网 IP 或域名。端口范围保持 `20000-30000`。

1. 在 A 入口机先生成 A 公钥：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/setup-ab-entry.sh -o setup-ab-entry.sh
sudo bash setup-ab-entry.sh
```

复制输出的 A 公钥。

2. 在 B 中继机运行，并填 A 地址、A 公钥、C 地址：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/setup-ab-relay.sh -o setup-ab-relay.sh
sudo A_ENDPOINT=A公网IP或域名 A_PUBLIC_KEY='A公钥' C_TARGET=C公网IP或域名 bash setup-ab-relay.sh
```

复制输出的 B 公钥。

3. 回到 A 入口机完成接入：

```bash
sudo B_PUBLIC_KEY='B公钥' bash setup-ab-entry.sh
```

完成后用户访问：

```text
A公网IP:23122
```

实际路径：

```text
用户 -> A:23122 -> B:23122 -> C:23122 -> 小鸡:22
```

脚本默认预转发 TCP/UDP `20000-30000`，端口号保持不变。C 上的面板/Incus 端口映射仍负责 `C:端口 -> 小鸡:端口`。

管理命令：

```bash
sudo ab-entry status
sudo ab-entry repair
sudo ab-entry restart
sudo ab-entry off
sudo ab-entry on

sudo ab-relay status
sudo ab-relay repair
sudo ab-relay restart
sudo ab-relay off
sudo ab-relay on
```

排查：

```bash
sudo ab-entry logs -n 80
sudo ab-relay logs -n 80
sudo ab-entry list
sudo ab-relay list
```

注意：这个模式只改变用户入口路径，不改变小鸡主动访问外网的出口。小鸡外网出口仍由 C 决定。

## 使用顺序

1. 在普通 VPS 运行 `setup-normal-vps.sh`，复制输出的客户端公钥。
2. 在家宽 VPS 运行 `setup-home-vps.sh`，粘贴普通 VPS 的客户端公钥。
3. 复制家宽 VPS 输出的服务端公钥。
4. 回到普通 VPS，继续输入家宽 VPS 地址、端口、服务端公钥，完成隧道配置。

## 常用检查

查看 WireGuard 状态：

```bash
sudo wg show
systemctl status wg-backend.service --no-pager -l
systemctl status wg-gateway.service --no-pager -l
```

查看出口 IP：

```bash
curl -4 https://ip.sb
```

停止隧道：

```bash
sudo wg-be off
sudo wg-gw off
```
