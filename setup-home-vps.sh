#!/usr/bin/env bash
# 家宽 VPS 出口端一键脚本
# 功能: WireGuard 服务端 + dnsmasq 黑名单 + BT/PT/金融过滤 + IPv4-only 出口
# 用法: sudo bash setup-home-vps.sh
# 可选: WG_PORT=443 sudo bash setup-home-vps.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "需要 root 权限 (sudo)"; exit 1; }
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu"; exit 1; }

WG_PORT="${WG_PORT:-}"
WG_NET="10.0.0.0/24"
WG_SERVER_IP="10.0.0.1"
WG_CLIENT_IP="10.0.0.2"
WG_MTU="1280"
TCP_MSS="1240"
WAN_IF="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
[[ -n "$WAN_IF" ]] || { echo "无法识别默认网卡"; exit 1; }

if [[ -z "$WG_PORT" ]]; then
  read -rp "WireGuard 监听端口 [51820]: " WG_PORT
  WG_PORT="${WG_PORT:-51820}"
fi
if ! [[ "$WG_PORT" =~ ^[0-9]+$ ]] || (( WG_PORT < 1 || WG_PORT > 65535 )); then
  echo "WireGuard 监听端口无效: $WG_PORT"
  exit 1
fi

echo "==> 默认出口网卡: $WAN_IF"
echo "==> WireGuard 监听: UDP $WG_PORT"

echo "==> 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard iptables iptables-persistent curl

echo "==> 预写 dnsmasq 配置，避免安装阶段抢占 53 端口"
mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/blocklist.conf <<'EOF'
# bind-dynamic: 即使监听地址暂未存在也能启动, 上线后自动绑定
listen-address=10.0.0.1
bind-dynamic
no-resolv
server=1.1.1.1
server=8.8.8.8
cache-size=1000

# === BT/PT Trackers ===
address=/opentrackr.org/0.0.0.0
address=/openbittorrent.com/0.0.0.0
address=/coppersurfer.tk/0.0.0.0
address=/leechers-paradise.org/0.0.0.0
address=/tracker.torrent.eu.org/0.0.0.0
address=/exodus.desync.com/0.0.0.0
address=/tracker.openbittorrent.com/0.0.0.0
address=/tracker.publicbt.com/0.0.0.0
address=/nyaa.si/0.0.0.0
address=/1337x.to/0.0.0.0
address=/thepiratebay.org/0.0.0.0
address=/rarbg.to/0.0.0.0

# === 加密货币交易所 ===
address=/binance.com/0.0.0.0
address=/okx.com/0.0.0.0
address=/huobi.com/0.0.0.0
address=/coinbase.com/0.0.0.0
address=/kraken.com/0.0.0.0
address=/bitfinex.com/0.0.0.0
address=/bybit.com/0.0.0.0
address=/gate.io/0.0.0.0

# === 股票券商 ===
address=/robinhood.com/0.0.0.0
address=/futunn.com/0.0.0.0
address=/futuhk.com/0.0.0.0
address=/tigerbrokers.com/0.0.0.0
address=/interactivebrokers.com/0.0.0.0

# === 中国大陆银行 / 支付 ===
address=/icbc.com.cn/0.0.0.0
address=/ccb.com/0.0.0.0
address=/abchina.com/0.0.0.0
address=/boc.cn/0.0.0.0
address=/cmbchina.com/0.0.0.0
address=/alipay.com/0.0.0.0
address=/tenpay.com/0.0.0.0

# === PayPal & 关联 ===
address=/paypal.com/0.0.0.0
address=/paypal.me/0.0.0.0
address=/paypalobjects.com/0.0.0.0
address=/paypal-corp.com/0.0.0.0
address=/venmo.com/0.0.0.0
address=/xoom.com/0.0.0.0
EOF

POLICY_BACKUP=""
POLICY_EXISTED=0
restore_policy_rc() {
  if [[ "$POLICY_EXISTED" -eq 1 && -n "$POLICY_BACKUP" && -e "$POLICY_BACKUP" ]]; then
    cp -a "$POLICY_BACKUP" /usr/sbin/policy-rc.d
    rm -f "$POLICY_BACKUP"
  else
    rm -f /usr/sbin/policy-rc.d
  fi
}
if [[ -e /usr/sbin/policy-rc.d ]]; then
  POLICY_EXISTED=1
  POLICY_BACKUP="$(mktemp)"
  cp -a /usr/sbin/policy-rc.d "$POLICY_BACKUP"
fi
cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
[ "$1" = "dnsmasq" ] && exit 101
exit 0
EOF
chmod 755 /usr/sbin/policy-rc.d
trap restore_policy_rc EXIT
apt-get install -y -qq dnsmasq
restore_policy_rc
trap - EXIT

echo "==> 开启 IPv4 转发并禁用 IPv6"
touch /etc/sysctl.conf
sed -i '/^net\.ipv4\.ip_forward/d;/^net\.ipv6\.conf\..*\.disable_ipv6/d' /etc/sysctl.conf
cat > /etc/sysctl.d/99-wg-ipv4-only.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true

echo "==> 生成 WireGuard 密钥"
mkdir -p /etc/wireguard && cd /etc/wireguard
umask 077
[[ -f server.key ]] || { wg genkey | tee server.key | wg pubkey > server.pub; }
SERVER_PUB="$(cat server.pub)"

echo "==> 清理旧版宽泛 iptables 规则"
while iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null; do :; done
while iptables -t mangle -D FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${TCP_MSS}" 2>/dev/null; do :; done
while iptables -t mangle -D FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${TCP_MSS}" 2>/dev/null; do :; done
while iptables -t nat -D POSTROUTING -o "${WAN_IF}" -j MASQUERADE 2>/dev/null; do :; done

echo
echo "============================================================"
echo " 家宽 VPS 公钥 (粘贴到普通 VPS 脚本):"
echo "   $SERVER_PUB"
echo "============================================================"
echo
read -rp "粘贴普通 VPS (客户端) 公钥: " CLIENT_PUB
[[ -n "$CLIENT_PUB" ]] || { echo "公钥不能为空"; exit 1; }

echo "==> 写入 /etc/wireguard/wg0.conf"
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = $(cat server.key)
MTU = ${WG_MTU}
PostUp = iptables -C INPUT -i wg0 -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -i wg0 -p udp --dport 53 -j ACCEPT
PostUp = iptables -C INPUT -i wg0 -p tcp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -i wg0 -p tcp --dport 53 -j ACCEPT
PostUp = iptables -t mangle -C FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${TCP_MSS} 2>/dev/null || iptables -t mangle -A FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${TCP_MSS}
PostUp = iptables -t mangle -C FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${TCP_MSS} 2>/dev/null || iptables -t mangle -A FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${TCP_MSS}
PostUp = iptables -C FORWARD -i wg0 -o ${WAN_IF} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i wg0 -o ${WAN_IF} -j ACCEPT
PostUp = iptables -C FORWARD -i ${WAN_IF} -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${WAN_IF} -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -t nat -C POSTROUTING -s ${WG_NET} -o ${WAN_IF} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${WG_NET} -o ${WAN_IF} -j MASQUERADE
PostDown = iptables -D INPUT -i wg0 -p udp --dport 53 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D INPUT -i wg0 -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${TCP_MSS} 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${TCP_MSS} 2>/dev/null || true
PostDown = iptables -D FORWARD -i wg0 -o ${WAN_IF} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i ${WAN_IF} -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NET} -o ${WAN_IF} -j MASQUERADE 2>/dev/null || true

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = ${WG_CLIENT_IP}/32
EOF
chmod 600 /etc/wireguard/wg0.conf

echo "==> 保持系统 DNS，只让 dnsmasq 监听 wg0"
if systemctl is-active --quiet systemd-resolved; then
  rm -f /etc/systemd/resolved.conf.d/no-stub.conf
  systemctl restart systemd-resolved || true
  [[ -f /run/systemd/resolve/stub-resolv.conf ]] && ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi

echo "==> 先启动 WireGuard (dnsmasq 需要 wg0 已存在)"
systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
systemctl restart wg-quick@wg0
sleep 1

echo "==> 配置 dnsmasq 黑名单 (BT/PT/金融/PayPal)"

systemctl enable dnsmasq >/dev/null 2>&1 || true
# 让 dnsmasq 在 wg-quick@wg0 之后启动
mkdir -p /etc/systemd/system/dnsmasq.service.d
cat > /etc/systemd/system/dnsmasq.service.d/after-wg.conf <<EOF
[Unit]
After=wg-quick@wg0.service
Wants=wg-quick@wg0.service
EOF
systemctl daemon-reload
systemctl restart dnsmasq

echo "==> 应用 iptables 过滤规则 (幂等)"
add_rule() { iptables -C "$@" 2>/dev/null || iptables -I "$@"; }
add_nat()  { iptables -t nat -C "$@" 2>/dev/null || iptables -t nat -I "$@"; }

# BT 协议特征
for s in "BitTorrent protocol" "BitTorrent" "peer_id=" "announce.php?passkey=" \
         "info_hash" "get_peers" "announce_peer" "find_node"; do
  add_rule FORWARD -m string --algo bm --string "$s" -j DROP
done
# BT/DHT 端口段
add_rule FORWARD -p tcp --dport 6881:6889 -j DROP
add_rule FORWARD -p udp --dport 6881:6889 -j DROP
add_rule FORWARD -p udp --dport 1337 -j DROP

# 拦截 DoT, 防客户端绕过 DNS
add_rule FORWARD -p tcp --dport 853 -j DROP
add_rule FORWARD -p udp --dport 853 -j DROP

# 强制客户端 DNS 走本机 dnsmasq
add_nat PREROUTING -i wg0 -p udp --dport 53 -j DNAT --to-destination ${WG_SERVER_IP}:53
add_nat PREROUTING -i wg0 -p tcp --dport 53 -j DNAT --to-destination ${WG_SERVER_IP}:53

echo "==> 持久化 iptables"
netfilter-persistent save >/dev/null

echo
echo "============================================================"
echo " 家宽 VPS 配置完成"
echo "------------------------------------------------------------"
echo " 服务端公钥:  $SERVER_PUB"
echo " 监听端口:    UDP ${WG_PORT}  (路由器/防火墙记得放行+端口转发)"
echo " 隧道网段:    10.0.0.0/24"
echo " 客户端 IP:   ${WG_CLIENT_IP}"
echo " MTU/MSS:     MTU ${WG_MTU}, TCP MSS ${TCP_MSS}"
echo "============================================================"
echo " 排查: wg show | journalctl -u wg-quick@wg0 | journalctl -u dnsmasq"
echo "============================================================"
