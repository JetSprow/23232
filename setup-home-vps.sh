#!/usr/bin/env bash
# 家宽 VPS 出口端一键脚本
# 功能: WireGuard 服务端 + dnsmasq 黑名单 + BT/PT/金融过滤 + IPv4 出口，支持 IPv4/IPv6 入口
# 用法: sudo bash setup-home-vps.sh
# 可选: WG_PORT=443 sudo bash setup-home-vps.sh
# 可选: ALLOW_IPS=普通机器公网IPv4或IPv6 sudo bash setup-home-vps.sh
set -euo pipefail
trap 'echo "[ERROR] 脚本在第 ${LINENO} 行退出: ${BASH_COMMAND}" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "需要 root 权限 (sudo)"; exit 1; }
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/JetSprow/23232/main}"
HOME_ALLOW_IPS="${HOME_ALLOW_IPS:-${ALLOW_IPS:-}}"
HOME_FIREWALL_LOCKDOWN="${HOME_FIREWALL_LOCKDOWN:-${LOCKDOWN_ALL:-0}}"
HOME_FIREWALL_SKIP="${HOME_FIREWALL_SKIP:-0}"

WG_PORT="${WG_PORT:-}"
WG_NET="10.0.0.0/24"
WG_SERVER_IP="10.0.0.1"
WG_CLIENT_IP="10.0.0.2"
WG_MTU_REQUEST="${WG_MTU:-1060}"
TCP_MSS_REQUEST="${TCP_MSS:-1020}"
WG_MTU="1060"
TCP_MSS="1020"
MTU_PROBE_TARGETS="${MTU_PROBE_TARGETS:-185.199.108.133 1.1.1.1 8.8.8.8}"
OLD_MSS_VALUES="1240 1200 1160 1140 1120 1100 1080 1040 1020 1000 984"
STATE_DIR="/etc/wg-home"
CONFIG_FILE="$STATE_DIR/config.env"
APPLY_BIN="/usr/local/sbin/wg-home-apply"
CHECK_BIN="/usr/local/sbin/wg-home-check"
RESTART_BIN="/usr/local/bin/wg-home-restart"
HELPER_BIN="/usr/local/bin/wg-home"
CHECK_UNIT_FILE="/etc/systemd/system/wg-home-check.service"
CHECK_TIMER_FILE="/etc/systemd/system/wg-home-check.timer"
WAN_IF="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
[[ -n "$WAN_IF" ]] || { echo "无法识别默认网卡"; exit 1; }

setup_home_firewall_whitelist() {
  local ports="$1" script_path tmp_script
  if [[ "$HOME_FIREWALL_SKIP" == "1" ]]; then
    echo "    [!] 已选择跳过家宽入口白名单防护。"
    return 0
  fi
  if [[ -z "$HOME_ALLOW_IPS" && -t 0 ]]; then
    echo
    echo "建议开启家宽入口 IP 白名单，只允许普通机器访问 WireGuard 入口。"
    read -rp "普通机器公网 IPv4/IPv6 白名单，多个用逗号分隔 [留空跳过]: " HOME_ALLOW_IPS
  fi
  if [[ -z "$HOME_ALLOW_IPS" ]]; then
    echo "    [!] 未配置 ALLOW_IPS，跳过家宽入口白名单防护。"
    echo "        建议重新运行: sudo ALLOW_IPS=普通机器公网IP或IPv6 bash setup-home-vps.sh"
    return 0
  fi
  script_path="${SCRIPT_DIR}/setup-home-firewall-whitelist.sh"
  if [[ -f "$script_path" ]]; then
    ALLOW_IPS="$HOME_ALLOW_IPS" PROTECT_PORTS="$ports" LOCKDOWN_ALL="$HOME_FIREWALL_LOCKDOWN" bash "$script_path"
    return
  fi
  tmp_script="$(mktemp)"
  curl -fsSL "${RAW_BASE}/setup-home-firewall-whitelist.sh" -o "$tmp_script"
  ALLOW_IPS="$HOME_ALLOW_IPS" PROTECT_PORTS="$ports" LOCKDOWN_ALL="$HOME_FIREWALL_LOCKDOWN" bash "$tmp_script"
  rm -f "$tmp_script"
}

detect_outer_mtu() {
  local target payload
  if ! command -v ping >/dev/null 2>&1; then
    echo 1200
    return 0
  fi
  for target in $MTU_PROBE_TARGETS; do
    for payload in 1372 1360 1320 1280 1240 1200 1160 1120 1080; do
      if timeout 4 ping -4 -c 1 -W 1 -M do -s "$payload" "$target" >/dev/null 2>&1; then
        echo $((payload + 28))
        return 0
      fi
    done
  done
  echo 1200
  return 0
}

auto_tune_mtu() {
  set +e
  if [[ "$WG_MTU_REQUEST" =~ ^[0-9]+$ ]]; then
    WG_MTU="$WG_MTU_REQUEST"
  else
    local outer_mtu
    outer_mtu="$(detect_outer_mtu)"
    [[ "$outer_mtu" =~ ^[0-9]+$ ]] || outer_mtu=1200
    WG_MTU=$((outer_mtu - 80))
    (( WG_MTU > 1280 )) && WG_MTU=1280
    (( WG_MTU < 1020 )) && WG_MTU=1020
  fi

  if [[ "$TCP_MSS_REQUEST" =~ ^[0-9]+$ ]]; then
    TCP_MSS="$TCP_MSS_REQUEST"
  else
    TCP_MSS=$((WG_MTU - 40))
    (( TCP_MSS < 980 )) && TCP_MSS=980
  fi
  set -e
  return 0
}

set_mtu_mss() {
  if [[ "${AUTO_MTU_PROBE:-0}" == "1" ]]; then
    auto_tune_mtu
    return 0
  fi
  [[ "$WG_MTU_REQUEST" =~ ^[0-9]+$ ]] && WG_MTU="$WG_MTU_REQUEST"
  [[ "$TCP_MSS_REQUEST" =~ ^[0-9]+$ ]] && TCP_MSS="$TCP_MSS_REQUEST"
}

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
apt-get install -y -qq wireguard iptables iptables-persistent curl iputils-ping

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

echo "==> 开启 IPv4 转发并保留 IPv6 入口能力"
touch /etc/sysctl.conf
sed -i '/^net\.ipv4\.ip_forward/d;/^net\.ipv6\.conf\..*\.disable_ipv6/d' /etc/sysctl.conf
rm -f /etc/sysctl.d/99-wg-ipv4-only.conf
cat > /etc/sysctl.d/99-wg-home.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.lo.disable_ipv6=0
EOF
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true

echo "==> 生成 WireGuard 密钥"
mkdir -p /etc/wireguard && cd /etc/wireguard
umask 077
[[ -f server.key ]] || { wg genkey | tee server.key | wg pubkey > server.pub; }
SERVER_PUB="$(cat server.pub)"

echo "==> 清理旧版宽泛 iptables 规则"
while iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null; do :; done
for old_mss in $OLD_MSS_VALUES; do
  while iptables -t mangle -D FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$old_mss" 2>/dev/null; do :; done
  while iptables -t mangle -D FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$old_mss" 2>/dev/null; do :; done
done
while iptables -t nat -D POSTROUTING -o "${WAN_IF}" -j MASQUERADE 2>/dev/null; do :; done
while iptables -t nat -D POSTROUTING -s "${WG_NET}" ! -d "${WG_NET}" -j MASQUERADE 2>/dev/null; do :; done

echo "==> 设置 WireGuard MTU/MSS"
set_mtu_mss
echo "    MTU = ${WG_MTU}, TCP MSS = ${TCP_MSS}"

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

mkdir -p "$STATE_DIR"
cat > "$CONFIG_FILE" <<EOF
WG_PORT=${WG_PORT}
WG_NET=${WG_NET}
WG_SERVER_IP=${WG_SERVER_IP}
WG_CLIENT_IP=${WG_CLIENT_IP}
WG_MTU=${WG_MTU}
TCP_MSS=${TCP_MSS}
WAN_IF=${WAN_IF}
EOF
chmod 600 "$CONFIG_FILE"

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

echo "==> 写入自修复脚本与 systemd 定时器"
cat > "$APPLY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/wg-home/config.env

current_wan="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
[[ -n "$current_wan" ]] && WAN_IF="$current_wan"

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true

if ! wg show wg0 >/dev/null 2>&1; then
  systemctl restart wg-quick@wg0
fi

systemctl restart dnsmasq >/dev/null 2>&1 || true

add_rule() { iptables -C "$@" 2>/dev/null || iptables -I "$@"; }
add_nat()  { iptables -t nat -C "$@" 2>/dev/null || iptables -t nat -I "$@"; }
add_mangle_append() { iptables -t mangle -C "$@" 2>/dev/null || iptables -t mangle -A "$@"; }
add_forward_append() { iptables -C "$@" 2>/dev/null || iptables -A "$@"; }
add_nat_append() { iptables -t nat -C "$@" 2>/dev/null || iptables -t nat -A "$@"; }

add_rule INPUT -i wg0 -p udp --dport 53 -j ACCEPT
add_rule INPUT -i wg0 -p tcp --dport 53 -j ACCEPT
add_mangle_append FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TCP_MSS"
add_mangle_append FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TCP_MSS"
add_forward_append FORWARD -i wg0 -j ACCEPT
add_forward_append FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
add_nat_append POSTROUTING -s "$WG_NET" ! -d "$WG_NET" -j MASQUERADE

for s in "BitTorrent protocol" "BitTorrent" "peer_id=" "announce.php?passkey=" \
         "info_hash" "get_peers" "announce_peer" "find_node"; do
  add_rule FORWARD -m string --algo bm --string "$s" -j DROP
done
add_rule FORWARD -p tcp --dport 6881:6889 -j DROP
add_rule FORWARD -p udp --dport 6881:6889 -j DROP
add_rule FORWARD -p udp --dport 1337 -j DROP
add_rule FORWARD -p tcp --dport 853 -j DROP
add_rule FORWARD -p udp --dport 853 -j DROP
add_nat PREROUTING -i wg0 -p udp --dport 53 -j DNAT --to-destination "${WG_SERVER_IP}:53"
add_nat PREROUTING -i wg0 -p tcp --dport 53 -j DNAT --to-destination "${WG_SERVER_IP}:53"

tmp="$(mktemp)"
awk -v wan="$WAN_IF" 'BEGIN{done=0} /^WAN_IF=/{print "WAN_IF=" wan; done=1; next} {print} END{if(!done) print "WAN_IF=" wan}' /etc/wg-home/config.env > "$tmp"
cat "$tmp" > /etc/wg-home/config.env
rm -f "$tmp"
EOF
chmod 755 "$APPLY_BIN"

cat > "$CHECK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/wg-home/config.env

repair=0
restart_needed=0
reason=()

need_repair() {
  repair=1
  reason+=("$*")
  logger -t wg-home-check "$*"
}

current_wan="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
if [[ -n "$current_wan" && "$current_wan" != "${WAN_IF:-}" ]]; then
  restart_needed=1
  need_repair "default interface changed: ${WAN_IF:-unknown} -> ${current_wan}"
fi

public_ip="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 6 https://ifconfig.me 2>/dev/null || true)"
if [[ -n "$public_ip" ]]; then
  last_file="/var/lib/wg-home-last-public-ip"
  last_ip="$(cat "$last_file" 2>/dev/null || true)"
  if [[ -n "$last_ip" && "$last_ip" != "$public_ip" ]]; then
    restart_needed=1
    need_repair "public IPv4 changed: ${last_ip} -> ${public_ip}"
  fi
  mkdir -p /var/lib
  printf '%s\n' "$public_ip" > "$last_file"
fi

wg show wg0 >/dev/null 2>&1 || need_repair "wg0 is not running"
systemctl is-active --quiet dnsmasq || need_repair "dnsmasq is not running"
iptables -t nat -C POSTROUTING -s "$WG_NET" ! -d "$WG_NET" -j MASQUERADE 2>/dev/null || need_repair "missing NAT MASQUERADE rule"
iptables -C FORWARD -i wg0 -j ACCEPT 2>/dev/null || need_repair "missing wg0 forward rule"
iptables -t nat -C PREROUTING -i wg0 -p udp --dport 53 -j DNAT --to-destination "${WG_SERVER_IP}:53" 2>/dev/null || need_repair "missing UDP DNS redirect"

if (( restart_needed )); then
  systemctl restart wg-quick@wg0 || true
  systemctl restart dnsmasq || true
fi
if (( repair )); then
  /usr/local/sbin/wg-home-apply
fi
EOF
chmod 755 "$CHECK_BIN"

cat > "$RESTART_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl restart wg-quick@wg0
systemctl restart dnsmasq || true
/usr/local/sbin/wg-home-apply
systemctl status wg-quick@wg0 dnsmasq --no-pager --lines=8
EOF
chmod 755 "$RESTART_BIN"

cat > "$HELPER_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-status}" in
  status) wg show wg0 || true; systemctl status wg-quick@wg0 dnsmasq wg-home-check.timer --no-pager --lines=8 ;;
  check) /usr/local/sbin/wg-home-check ;;
  apply) /usr/local/sbin/wg-home-apply ;;
  restart) /usr/local/bin/wg-home-restart ;;
  logs) journalctl -u wg-quick@wg0 -u dnsmasq -u wg-home-check.service --no-pager "${@:2}" ;;
  *) echo "usage: wg-home status|check|apply|restart|logs" >&2; exit 2 ;;
esac
EOF
chmod 755 "$HELPER_BIN"

cat > "$CHECK_UNIT_FILE" <<EOF
[Unit]
Description=WireGuard home exit self-heal check
After=network-online.target wg-quick@wg0.service dnsmasq.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CHECK_BIN}
EOF

cat > "$CHECK_TIMER_FILE" <<'EOF'
[Unit]
Description=Run WireGuard home exit self-heal check

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
EOF

mkdir -p /etc/systemd/system/wg-quick@wg0.service.d
cat > /etc/systemd/system/wg-quick@wg0.service.d/10-incusse-home-restart.conf <<'EOF'
[Service]
Restart=on-failure
RestartSec=5s
EOF

systemctl daemon-reload
systemctl enable --now wg-home-check.timer >/dev/null 2>&1 || true
setup_home_firewall_whitelist "${WG_PORT}/udp"

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
echo " 自修复:      wg-home-check.timer 每 30 秒检查 IP/接口/规则"
echo "============================================================"
echo " 一键重启:    wg-home-restart"
echo " 排查:        wg-home status | wg-home logs -n 80"
echo "============================================================"
