# WireGuard 家宽出口脚本

这个仓库包含 3 个脚本：

- `setup-home-vps.sh`：家宽 VPS 出口端，配置 WireGuard 服务端、NAT、DNS 与基础过滤规则。
- `setup-normal-vps.sh`：普通 VPS 客户端，将 IPv4 出口切到家宽 VPS，并保留 SSH 连接。
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

脚本默认自动探测并设置 WireGuard `MTU` 和 TCP `MSS`。如需手动指定：

```bash
sudo WG_MTU=1180 TCP_MSS=1140 bash setup-normal-vps.sh
sudo WG_MTU=1180 TCP_MSS=1140 bash setup-home-vps.sh
```

诊断 GitHub Raw / Check.Place 卡住：

```bash
curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/diagnose-github-raw.sh -o diagnose-github-raw.sh
sudo bash diagnose-github-raw.sh 2>&1 | tee /tmp/github-raw-diagnose.log
```

## 使用顺序

1. 在普通 VPS 运行 `setup-normal-vps.sh`，复制输出的客户端公钥。
2. 在家宽 VPS 运行 `setup-home-vps.sh`，粘贴普通 VPS 的客户端公钥。
3. 复制家宽 VPS 输出的服务端公钥。
4. 回到普通 VPS，继续输入家宽 VPS 地址、端口、服务端公钥，完成隧道配置。

## 常用检查

查看 WireGuard 状态：

```bash
sudo wg show
systemctl status wg-quick@wg0 --no-pager -l
```

查看出口 IP：

```bash
curl -4 https://ip.sb
```

停止隧道：

```bash
sudo wg-quick down wg0
```
