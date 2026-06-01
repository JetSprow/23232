#!/usr/bin/env bash
# 普通 VPS 客户端一键脚本
# 功能: 全 IPv4 流量走家宽 VPS 出口 (保留 SSH 不断连)
# 用法: sudo bash setup-normal-vps.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "需要 root 权限 (sudo)"; exit 1; }
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu"; exit 1; }

WG_SERVER_IP="10.0.0.1"
WG_CLIENT_IP="10.0.0.2"
WG_PORT_DEFAULT="51820"
DNS_VIA_TUNNEL="10.0.0.1"
WG_TABLE="51820"
WG_FWMARK="51820"
WG_MTU_REQUEST="${WG_MTU:-auto}"
TCP_MSS_REQUEST="${TCP_MSS:-auto}"
WG_MTU="1280"
TCP_MSS="1240"
DNS_HELPER="/usr/local/sbin/wg-ipv4-dns"
OLD_MSS_VALUES="1240 1200 1160 1140 1120 1100 1080 1040"

detect_outer_mtu() {
  local target="$1"
  local payload
  for payload in 1372 1360 1320 1280 1240 1200 1160 1120 1080; do
    if timeout 4 ping -4 -c 2 -W 1 -M do -s "$payload" "$target" 2>/dev/null | grep -q ' 0% packet loss'; then
      echo $((payload + 28))
      return
    fi
  done
  echo 1200
}

auto_tune_mtu() {
  local target="$1"
  if [[ "$WG_MTU_REQUEST" != "auto" ]]; then
    WG_MTU="$WG_MTU_REQUEST"
  else
    local outer_mtu
    outer_mtu="$(detect_outer_mtu "$target")"
    WG_MTU=$((outer_mtu - 80))
    (( WG_MTU > 1280 )) && WG_MTU=1280
    (( WG_MTU < 1080 )) && WG_MTU=1080
  fi

  if [[ "$TCP_MSS_REQUEST" != "auto" ]]; then
    TCP_MSS="$TCP_MSS_REQUEST"
  else
    TCP_MSS=$((WG_MTU - 40))
    (( TCP_MSS < 1040 )) && TCP_MSS=1040
  fi
}

echo "==> 预清理旧 WireGuard 路由，避免安装阶段没网"
systemctl stop wg-quick@wg0 >/dev/null 2>&1 || true
while ip -4 rule del not from "${WG_CLIENT_IP}" table 200 priority 200 2>/dev/null; do :; done
ip -4 route flush table 200 2>/dev/null || true
while ip -4 rule del fwmark "${WG_FWMARK}" table main priority 100 2>/dev/null; do :; done
while ip -4 rule del table main suppress_prefixlength 0 priority 101 2>/dev/null; do :; done
while ip -4 rule del not fwmark "${WG_FWMARK}" table "${WG_TABLE}" priority 102 2>/dev/null; do :; done
ip -4 route flush table "${WG_TABLE}" 2>/dev/null || true
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved && [[ -f /run/systemd/resolve/stub-resolv.conf ]]; then
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
else
  rm -f /etc/resolv.conf
  printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions timeout:2 attempts:2\n" > /etc/resolv.conf
fi
ip -4 route flush cache 2>/dev/null || true

echo "==> 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard iproute2 curl iptables ca-certificates

WAN_IF="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
GATEWAY="$(ip -4 route show default | awk '/default/ {print $3; exit}')"
LOCAL_IP="$(ip -4 -o addr show dev "$WAN_IF" scope global | awk '{split($4,a,"/"); print a[1]; exit}')"
[[ -n "$WAN_IF" && -n "$LOCAL_IP" ]] || { echo "无法识别 IPv4 默认网卡/本机地址"; exit 1; }

DETECTED_SSH_PORTS="$(
  ss -H -ltnp 2>/dev/null \
    | awk '/sshd/ {n=split($4,a,":"); print a[n]}' \
    | sed 's/[^0-9].*$//' \
    | awk 'NF' \
    | sort -nu \
    | head -n 15 \
    | paste -sd, -
)"
SSH_PORTS="${SSH_PORTS:-${DETECTED_SSH_PORTS:-22}}"

echo "    默认网卡 = $WAN_IF, 网关 = ${GATEWAY:-on-link}, 本机 IPv4 = $LOCAL_IP"
echo "    SSH 端口 = $SSH_PORTS"

echo "==> 清理旧版策略路由/标记规则"
while ip -4 rule del not from "${WG_CLIENT_IP}" table 200 priority 200 2>/dev/null; do :; done
while ip -4 rule del from "${LOCAL_IP}" table main priority 100 2>/dev/null; do :; done
ip -4 route flush table 200 2>/dev/null || true

while ip -4 rule del fwmark "${WG_FWMARK}" table main priority 100 2>/dev/null; do :; done
while ip -4 rule del table main suppress_prefixlength 0 priority 101 2>/dev/null; do :; done
while ip -4 rule del not fwmark "${WG_FWMARK}" table "${WG_TABLE}" priority 102 2>/dev/null; do :; done
ip -4 route flush table "${WG_TABLE}" 2>/dev/null || true
while iptables -t mangle -D OUTPUT -p tcp -m multiport --sports "${SSH_PORTS}" -j MARK --set-mark "${WG_FWMARK}" 2>/dev/null; do :; done
for old_mss in $OLD_MSS_VALUES; do
  while iptables -t mangle -D OUTPUT -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$old_mss" 2>/dev/null; do :; done
  while iptables -t mangle -D FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$old_mss" 2>/dev/null; do :; done
done
while iptables -t mangle -D OUTPUT -m mark --mark 0x0 -m connmark --mark "${WG_FWMARK}" -j CONNMARK --restore-mark 2>/dev/null; do :; done
while iptables -t mangle -D PREROUTING -j CONNMARK --restore-mark 2>/dev/null; do :; done
while iptables -t mangle -D PREROUTING -i "${WAN_IF}" -m conntrack --ctstate NEW -j CONNMARK --set-mark "${WG_FWMARK}" 2>/dev/null; do :; done

echo "==> 获取本机公网 IP (用于验证)"
PUB_IP="$(curl -4 -s --max-time 5 ifconfig.me | tr -d '\r\n' || true)"
[[ -z "$PUB_IP" ]] && PUB_IP="$(curl -4 -s --max-time 5 ipinfo.io/ip | tr -d '\r\n' || true)"
PUB_IP="${PUB_IP:-获取失败}"
echo "    本机公网 IP = $PUB_IP"
if [[ "$PUB_IP" != "获取失败" ]]; then
  while ip -4 rule del from "${PUB_IP}" table main priority 100 2>/dev/null; do :; done
fi

echo "==> 开启 IPv4-only 模式"
touch /etc/sysctl.conf
sed -i '/^net\.ipv6\.conf\..*\.disable_ipv6/d' /etc/sysctl.conf
cat > /etc/sysctl.d/99-wg-ipv4-only.conf <<EOF
net.ipv4.conf.all.src_valid_mark=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true

echo "==> 生成 WireGuard 密钥"
mkdir -p /etc/wireguard && cd /etc/wireguard
umask 077
[[ -f client.key ]] || { wg genkey | tee client.key | wg pubkey > client.pub; }
CLIENT_PUB="$(cat client.pub)"

echo
echo "============================================================"
echo " 普通 VPS (客户端) 公钥，粘贴到家宽 VPS 脚本:"
echo "   $CLIENT_PUB"
echo "============================================================"
echo
read -rp "家宽 VPS 公网 IPv4/域名: " HOME_ENDPOINT
read -rp "家宽 VPS 监听端口 [${WG_PORT_DEFAULT}]: " HOME_PORT
HOME_PORT="${HOME_PORT:-$WG_PORT_DEFAULT}"
read -rp "家宽 VPS 服务端公钥: " SERVER_PUB
[[ -n "$HOME_ENDPOINT" && -n "$SERVER_PUB" ]] || { echo "参数不能为空"; exit 1; }

if [[ "$HOME_ENDPOINT" == *:* ]]; then
  echo "只支持 IPv4 Endpoint，请输入 IPv4 地址或解析到 A 记录的域名"
  exit 1
fi

if [[ "$HOME_ENDPOINT" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  HOME_ENDPOINT_IPV4="$HOME_ENDPOINT"
else
  HOME_ENDPOINT_IPV4="$(getent ahostsv4 "$HOME_ENDPOINT" | awk '{print $1; exit}')"
fi
[[ -n "$HOME_ENDPOINT_IPV4" ]] || { echo "无法解析家宽 VPS 的 IPv4 A 记录"; exit 1; }
echo "    家宽 Endpoint IPv4 = ${HOME_ENDPOINT_IPV4}:${HOME_PORT}"

echo "==> 自动探测 WireGuard MTU/MSS"
auto_tune_mtu "$HOME_ENDPOINT_IPV4"
echo "    MTU = ${WG_MTU}, TCP MSS = ${TCP_MSS}"

echo "==> 写入 DNS 切换助手"
mkdir -p "$(dirname "$DNS_HELPER")"
cat > "$DNS_HELPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
IFACE="${2:-wg0}"
DNS="${3:-10.0.0.1}"
BACKUP="/run/${IFACE}.resolv.conf.backup"

case "$ACTION" in
  up)
    if command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved; then
      resolvectl dns "$IFACE" "$DNS" >/dev/null || true
      resolvectl domain "$IFACE" "~." >/dev/null || true
      resolvectl default-route "$IFACE" yes >/dev/null || true
    else
      [[ -e /etc/resolv.conf && ! -e "$BACKUP" ]] && cp -af /etc/resolv.conf "$BACKUP" 2>/dev/null || true
      rm -f /etc/resolv.conf
      printf "nameserver %s\noptions timeout:2 attempts:2\n" "$DNS" > /etc/resolv.conf
    fi
    ;;
  down)
    if command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved; then
      resolvectl revert "$IFACE" >/dev/null || true
    elif [[ -e "$BACKUP" ]]; then
      cp -af "$BACKUP" /etc/resolv.conf 2>/dev/null || true
      rm -f "$BACKUP"
    fi
    ;;
  *)
    echo "usage: wg-ipv4-dns up|down [iface] [dns]" >&2
    exit 2
    ;;
esac
EOF
chmod 755 "$DNS_HELPER"

echo "==> 写入 /etc/wireguard/wg0.conf (IPv4 全隧道 + SSH 保留)"
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${WG_CLIENT_IP}/24
PrivateKey = $(cat client.key)
Table = off
FwMark = ${WG_FWMARK}
MTU = ${WG_MTU}
PostUp = iptables -t mangle -C OUTPUT -p tcp -m multiport --sports ${SSH_PORTS} -j MARK --set-mark ${WG_FWMARK} 2>/dev/null || iptables -t mangle -A OUTPUT -p tcp -m multiport --sports ${SSH_PORTS} -j MARK --set-mark ${WG_FWMARK}
PostUp = iptables -t mangle -C OUTPUT -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${TCP_MSS} 2>/dev/null || iptables -t mangle -A OUTPUT -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${TCP_MSS}
PostUp = iptables -t mangle -C FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${TCP_MSS} 2>/dev/null || iptables -t mangle -A FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${TCP_MSS}
PostUp = iptables -t mangle -C PREROUTING -i ${WAN_IF} -m conntrack --ctstate NEW -j CONNMARK --set-mark ${WG_FWMARK} 2>/dev/null || iptables -t mangle -A PREROUTING -i ${WAN_IF} -m conntrack --ctstate NEW -j CONNMARK --set-mark ${WG_FWMARK}
PostUp = iptables -t mangle -C PREROUTING -j CONNMARK --restore-mark 2>/dev/null || iptables -t mangle -A PREROUTING -j CONNMARK --restore-mark
PostUp = iptables -t mangle -C OUTPUT -m mark --mark 0x0 -m connmark --mark ${WG_FWMARK} -j CONNMARK --restore-mark 2>/dev/null || iptables -t mangle -A OUTPUT -m mark --mark 0x0 -m connmark --mark ${WG_FWMARK} -j CONNMARK --restore-mark
PostUp = ip -4 rule add fwmark ${WG_FWMARK} table main priority 100 2>/dev/null || true
PostUp = ip -4 rule add table main suppress_prefixlength 0 priority 101 2>/dev/null || true
PostUp = ip -4 rule add not fwmark ${WG_FWMARK} table ${WG_TABLE} priority 102 2>/dev/null || true
PostUp = ip -4 route replace default dev wg0 table ${WG_TABLE}
PostUp = ip -4 route flush cache || true
PostDown = ip -4 route flush table ${WG_TABLE} 2>/dev/null || true
PostDown = ip -4 rule del not fwmark ${WG_FWMARK} table ${WG_TABLE} priority 102 2>/dev/null || true
PostDown = ip -4 rule del table main suppress_prefixlength 0 priority 101 2>/dev/null || true
PostDown = ip -4 rule del fwmark ${WG_FWMARK} table main priority 100 2>/dev/null || true
PostDown = iptables -t mangle -D OUTPUT -p tcp -m multiport --sports ${SSH_PORTS} -j MARK --set-mark ${WG_FWMARK} 2>/dev/null || true
PostDown = iptables -t mangle -D OUTPUT -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${TCP_MSS} 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${TCP_MSS} 2>/dev/null || true
PostDown = iptables -t mangle -D OUTPUT -m mark --mark 0x0 -m connmark --mark ${WG_FWMARK} -j CONNMARK --restore-mark 2>/dev/null || true
PostDown = iptables -t mangle -D PREROUTING -j CONNMARK --restore-mark 2>/dev/null || true
PostDown = iptables -t mangle -D PREROUTING -i ${WAN_IF} -m conntrack --ctstate NEW -j CONNMARK --set-mark ${WG_FWMARK} 2>/dev/null || true
PostDown = ip -4 route flush cache || true

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${HOME_ENDPOINT_IPV4}:${HOME_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 /etc/wireguard/wg0.conf

echo "==> 启动 WireGuard"
systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
systemctl restart wg-quick@wg0

sleep 2
echo
echo "==> 验证 (出口 IP 应为家宽 IP)"
NEW_IP="$(curl -4 -s --max-time 8 ifconfig.me | tr -d '\r\n' || echo '获取失败')"
echo "    当前出口 IP: $NEW_IP"
echo "    原公网 IP:   $PUB_IP"
if [[ "$NEW_IP" == "$PUB_IP" || "$NEW_IP" == "获取失败" ]]; then
  echo "    [!] 出口未切换或 DNS/转发未通，检查: wg show / 家宽端口 / 家宽端 NAT"
else
  echo "    [OK] IPv4 流量已走家宽出口"
fi

echo
echo "============================================================"
echo " 普通 VPS 配置完成"
echo "------------------------------------------------------------"
echo " 客户端公钥:  $CLIENT_PUB"
echo " 隧道地址:    ${WG_CLIENT_IP}"
echo " 出口端点:    ${HOME_ENDPOINT_IPV4}:${HOME_PORT}"
echo " SSH 保留:    TCP 源端口 ${SSH_PORTS} 走原公网出口"
echo " MTU/MSS:     MTU ${WG_MTU}, TCP MSS ${TCP_MSS}"
echo " IPv6:        已禁用，不配置 IPv6 隧道路由"
echo "============================================================"
echo " 失联兜底: 配置前先 (crontab -e) 加一行 5 分钟自动断开:"
echo "   */5 * * * * wg-quick down wg0"
echo " 测试稳定后再删掉这行."
echo "============================================================"
