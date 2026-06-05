#!/usr/bin/env bash
# 普通 VPS 客户端一键脚本
# 功能: 全 IPv4 流量走家宽 VPS 出口 (保留 SSH 不断连)
# 用法: sudo bash setup-normal-vps.sh
set -euo pipefail
trap 'echo "[ERROR] 脚本在第 ${LINENO} 行退出: ${BASH_COMMAND}" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "需要 root 权限 (sudo)"; exit 1; }
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu"; exit 1; }

WG_SERVER_IP="10.0.0.1"
WG_CLIENT_IP="10.0.0.2"
WG_PORT_DEFAULT="51820"
DNS_VIA_TUNNEL="10.0.0.1"
WG_TABLE="51820"
WG_FWMARK="51820"
WG_MTU_REQUEST="${WG_MTU:-1060}"
TCP_MSS_REQUEST="${TCP_MSS:-1020}"
WG_MTU="1060"
TCP_MSS="1020"
DNS_HELPER="/usr/local/sbin/wg-ipv4-dns"
OLD_MSS_VALUES="1240 1200 1160 1140 1120 1100 1080 1040 1020 1000 984"
STATE_DIR="/etc/wg-normal"
CONFIG_FILE="$STATE_DIR/config.env"
APPLY_BIN="/usr/local/sbin/wg-normal-apply"
CHECK_BIN="/usr/local/sbin/wg-normal-check"
FALLBACK_BIN="/usr/local/sbin/wg-normal-fallback"
RECOVER_BIN="/usr/local/sbin/wg-normal-recover"
RESTART_BIN="/usr/local/bin/wg-normal-restart"
HELPER_BIN="/usr/local/bin/wg-normal"
CHECK_UNIT_FILE="/etc/systemd/system/wg-normal-check.service"
CHECK_TIMER_FILE="/etc/systemd/system/wg-normal-check.timer"
MODE_FILE="$STATE_DIR/mode"

detect_outer_mtu() {
  local target="$1"
  local payload
  if ! command -v ping >/dev/null 2>&1; then
    echo 1200
    return 0
  fi
  for payload in 1372 1360 1320 1280 1240 1200 1160 1120 1080; do
    if timeout 4 ping -4 -c 1 -W 1 -M do -s "$payload" "$target" >/dev/null 2>&1; then
      echo $((payload + 28))
      return 0
    fi
  done
  echo 1200
  return 0
}

auto_tune_mtu() {
  local target="$1"
  set +e
  if [[ "$WG_MTU_REQUEST" =~ ^[0-9]+$ ]]; then
    WG_MTU="$WG_MTU_REQUEST"
  else
    local outer_mtu
    outer_mtu="$(detect_outer_mtu "$target")"
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
    auto_tune_mtu "$1"
    return 0
  fi
  [[ "$WG_MTU_REQUEST" =~ ^[0-9]+$ ]] && WG_MTU="$WG_MTU_REQUEST"
  [[ "$TCP_MSS_REQUEST" =~ ^[0-9]+$ ]] && TCP_MSS="$TCP_MSS_REQUEST"
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
apt-get install -y -qq wireguard iproute2 curl iptables ca-certificates iputils-ping

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
while iptables -t mangle -D OUTPUT -p udp --dport 53 -j MARK --set-mark "${WG_FWMARK}" 2>/dev/null; do :; done
while iptables -t mangle -D OUTPUT -p tcp --dport 53 -j MARK --set-mark "${WG_FWMARK}" 2>/dev/null; do :; done
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

echo "==> 设置 WireGuard MTU/MSS"
set_mtu_mss "$HOME_ENDPOINT_IPV4"
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
PostUp = iptables -t mangle -C OUTPUT -p udp --dport 53 -j MARK --set-mark ${WG_FWMARK} 2>/dev/null || iptables -t mangle -A OUTPUT -p udp --dport 53 -j MARK --set-mark ${WG_FWMARK}
PostUp = iptables -t mangle -C OUTPUT -p tcp --dport 53 -j MARK --set-mark ${WG_FWMARK} 2>/dev/null || iptables -t mangle -A OUTPUT -p tcp --dport 53 -j MARK --set-mark ${WG_FWMARK}
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
PostDown = iptables -t mangle -D OUTPUT -p udp --dport 53 -j MARK --set-mark ${WG_FWMARK} 2>/dev/null || true
PostDown = iptables -t mangle -D OUTPUT -p tcp --dport 53 -j MARK --set-mark ${WG_FWMARK} 2>/dev/null || true
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

mkdir -p "$STATE_DIR"
cat > "$CONFIG_FILE" <<EOF
WG_SERVER_IP=${WG_SERVER_IP}
WG_CLIENT_IP=${WG_CLIENT_IP}
HOME_ENDPOINT=${HOME_ENDPOINT}
HOME_ENDPOINT_IPV4=${HOME_ENDPOINT_IPV4}
HOME_PORT=${HOME_PORT}
SERVER_PUB=${SERVER_PUB}
DNS_VIA_TUNNEL=${DNS_VIA_TUNNEL}
WG_TABLE=${WG_TABLE}
WG_FWMARK=${WG_FWMARK}
WG_MTU=${WG_MTU}
TCP_MSS=${TCP_MSS}
WAN_IF=${WAN_IF}
SSH_PORTS=${SSH_PORTS}
MODE_FILE=${MODE_FILE}
EOF
chmod 600 "$CONFIG_FILE"
printf 'home\n' > "$MODE_FILE"
chmod 600 "$MODE_FILE"

echo "==> 写入自修复脚本与 systemd 定时器"
cat > "$APPLY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/wg-normal/config.env

resolve_endpoint() {
  local endpoint="$1"
  if [[ "$endpoint" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "$endpoint"
    return 0
  fi
  local ns added_rules=() result
  while read -r ns; do
    [[ "$ns" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
    if ip -4 rule add to "${ns}/32" table main priority 99 2>/dev/null; then
      added_rules+=("$ns")
    fi
  done < <(awk '/^nameserver[[:space:]]+[0-9.]+/ {print $2}' /etc/resolv.conf 2>/dev/null | head -n 3)
  result="$(getent ahostsv4 "$endpoint" | awk '{print $1; exit}' || true)"
  for ns in "${added_rules[@]}"; do
    ip -4 rule del to "${ns}/32" table main priority 99 2>/dev/null || true
  done
  printf '%s\n' "$result"
}

update_config_value() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" 'BEGIN{done=0} index($0,key"=")==1{print key"="value; done=1; next} {print} END{if(!done) print key"="value}' /etc/wg-normal/config.env > "$tmp"
  cat "$tmp" > /etc/wg-normal/config.env
  rm -f "$tmp"
}

current_wan="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
[[ -n "$current_wan" ]] && WAN_IF="$current_wan"

new_endpoint="$(resolve_endpoint "$HOME_ENDPOINT" || true)"
if [[ -n "$new_endpoint" && "$new_endpoint" != "$HOME_ENDPOINT_IPV4" ]]; then
  logger -t wg-normal-apply "home endpoint changed: ${HOME_ENDPOINT_IPV4} -> ${new_endpoint}"
  sed -i "s#^Endpoint = .*#Endpoint = ${new_endpoint}:${HOME_PORT}#" /etc/wireguard/wg0.conf
  HOME_ENDPOINT_IPV4="$new_endpoint"
  update_config_value HOME_ENDPOINT_IPV4 "$HOME_ENDPOINT_IPV4"
fi
update_config_value WAN_IF "$WAN_IF"

sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true

if ! wg show wg0 >/dev/null 2>&1; then
  systemctl restart wg-quick@wg0
fi

wg set wg0 peer "$SERVER_PUB" endpoint "${HOME_ENDPOINT_IPV4}:${HOME_PORT}" persistent-keepalive 25 >/dev/null 2>&1 || true

iptables -t mangle -C OUTPUT -p tcp -m multiport --sports "$SSH_PORTS" -j MARK --set-mark "$WG_FWMARK" 2>/dev/null || iptables -t mangle -A OUTPUT -p tcp -m multiport --sports "$SSH_PORTS" -j MARK --set-mark "$WG_FWMARK"
iptables -t mangle -C OUTPUT -p udp --dport 53 -j MARK --set-mark "$WG_FWMARK" 2>/dev/null || iptables -t mangle -A OUTPUT -p udp --dport 53 -j MARK --set-mark "$WG_FWMARK"
iptables -t mangle -C OUTPUT -p tcp --dport 53 -j MARK --set-mark "$WG_FWMARK" 2>/dev/null || iptables -t mangle -A OUTPUT -p tcp --dport 53 -j MARK --set-mark "$WG_FWMARK"
iptables -t mangle -C OUTPUT -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TCP_MSS" 2>/dev/null || iptables -t mangle -A OUTPUT -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TCP_MSS"
iptables -t mangle -C FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TCP_MSS" 2>/dev/null || iptables -t mangle -A FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TCP_MSS"
iptables -t mangle -C PREROUTING -i "$WAN_IF" -m conntrack --ctstate NEW -j CONNMARK --set-mark "$WG_FWMARK" 2>/dev/null || iptables -t mangle -A PREROUTING -i "$WAN_IF" -m conntrack --ctstate NEW -j CONNMARK --set-mark "$WG_FWMARK"
iptables -t mangle -C PREROUTING -j CONNMARK --restore-mark 2>/dev/null || iptables -t mangle -A PREROUTING -j CONNMARK --restore-mark
iptables -t mangle -C OUTPUT -m mark --mark 0x0 -m connmark --mark "$WG_FWMARK" -j CONNMARK --restore-mark 2>/dev/null || iptables -t mangle -A OUTPUT -m mark --mark 0x0 -m connmark --mark "$WG_FWMARK" -j CONNMARK --restore-mark

ip -4 rule add fwmark "$WG_FWMARK" table main priority 100 2>/dev/null || true
ip -4 rule add table main suppress_prefixlength 0 priority 101 2>/dev/null || true
ip -4 rule add not fwmark "$WG_FWMARK" table "$WG_TABLE" priority 102 2>/dev/null || true
ip -4 route replace default dev wg0 table "$WG_TABLE"
ip -4 route flush cache 2>/dev/null || true
EOF
chmod 755 "$APPLY_BIN"

cat > "$FALLBACK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/wg-normal/config.env

reason="${1:-home egress unavailable}"
logger -t wg-normal-fallback "fallback to local egress: ${reason}"

ip -4 route flush table "$WG_TABLE" 2>/dev/null || true
ip -4 rule del not fwmark "$WG_FWMARK" table "$WG_TABLE" priority 102 2>/dev/null || true
ip -4 rule del table main suppress_prefixlength 0 priority 101 2>/dev/null || true
ip -4 rule del fwmark "$WG_FWMARK" table main priority 100 2>/dev/null || true
ip -4 route flush cache 2>/dev/null || true

mkdir -p "$(dirname "$MODE_FILE")"
printf 'local\n' > "$MODE_FILE"
chmod 600 "$MODE_FILE"
EOF
chmod 755 "$FALLBACK_BIN"

cat > "$RECOVER_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/wg-normal/config.env

logger -t wg-normal-recover "attempting home egress recovery"

/usr/local/sbin/wg-normal-apply || {
  /usr/local/sbin/wg-normal-fallback "apply failed during recovery"
  exit 1
}

sleep 3

latest="$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2; exit}' || true)"
now="$(date +%s)"
if [[ -z "$latest" || "$latest" == "0" || $((now - latest)) -gt 180 ]]; then
  /usr/local/sbin/wg-normal-fallback "WireGuard handshake unavailable after recovery"
  exit 1
fi

ok=0
for url in https://api.ipify.org https://ip.sb https://ifconfig.me; do
  if curl -4 --connect-timeout 8 --max-time 20 -fsS "$url" >/dev/null 2>&1; then
    ok=1
    break
  fi
done

if (( ok )); then
  printf 'home\n' > "$MODE_FILE"
  chmod 600 "$MODE_FILE"
  logger -t wg-normal-recover "home egress recovered"
  exit 0
fi

/usr/local/sbin/wg-normal-fallback "IPv4 egress test failed after recovery"
exit 1
EOF
chmod 755 "$RECOVER_BIN"

cat > "$CHECK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/wg-normal/config.env

repair=0
restart=0
mode="$(cat "$MODE_FILE" 2>/dev/null || echo home)"
if [[ "$mode" == "local" ]]; then
  if /usr/local/sbin/wg-normal-recover; then
    exit 0
  fi
  logger -t wg-normal-check "home egress still unavailable; keeping local egress until next 5 minute check"
  exit 0
fi

resolve_endpoint() {
  local endpoint="$1"
  if [[ "$endpoint" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "$endpoint"
    return 0
  fi
  local ns added_rules=() result
  while read -r ns; do
    [[ "$ns" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
    if ip -4 rule add to "${ns}/32" table main priority 99 2>/dev/null; then
      added_rules+=("$ns")
    fi
  done < <(awk '/^nameserver[[:space:]]+[0-9.]+/ {print $2}' /etc/resolv.conf 2>/dev/null | head -n 3)
  result="$(getent ahostsv4 "$endpoint" | awk '{print $1; exit}' || true)"
  for ns in "${added_rules[@]}"; do
    ip -4 rule del to "${ns}/32" table main priority 99 2>/dev/null || true
  done
  printf '%s\n' "$result"
}

need_repair() {
  repair=1
  logger -t wg-normal-check "$*"
}

current_wan="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
if [[ -n "$current_wan" && "$current_wan" != "${WAN_IF:-}" ]]; then
  need_repair "default interface changed: ${WAN_IF:-unknown} -> ${current_wan}"
fi

resolved="$(resolve_endpoint "$HOME_ENDPOINT" || true)"
if [[ -n "$resolved" && "$resolved" != "$HOME_ENDPOINT_IPV4" ]]; then
  restart=1
  need_repair "home endpoint A record changed: ${HOME_ENDPOINT_IPV4} -> ${resolved}"
fi

if ! wg show wg0 >/dev/null 2>&1; then
  restart=1
  need_repair "wg0 is not running"
else
  now="$(date +%s)"
  latest="$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2; exit}')"
  if [[ -z "$latest" || "$latest" == "0" ]]; then
    restart=1
    need_repair "WireGuard has no handshake"
  elif (( now - latest > 180 )); then
    restart=1
    need_repair "WireGuard handshake is stale: $((now - latest))s"
  fi
fi

ip -4 route show table "$WG_TABLE" | grep -q '^default dev wg0' || need_repair "missing wg table default route"
ip -4 rule show | grep -F "not from all fwmark 0x$(printf '%x' "$WG_FWMARK") lookup $WG_TABLE" >/dev/null || ip -4 rule show | grep -F "not from all fwmark $WG_FWMARK lookup $WG_TABLE" >/dev/null || need_repair "missing wg policy rule"
iptables -t mangle -C OUTPUT -p tcp -m multiport --sports "$SSH_PORTS" -j MARK --set-mark "$WG_FWMARK" 2>/dev/null || need_repair "missing SSH keepalive mark rule"
iptables -t mangle -C OUTPUT -p udp --dport 53 -j MARK --set-mark "$WG_FWMARK" 2>/dev/null || need_repair "missing DNS keepalive mark rule"

if (( restart )); then
  systemctl restart wg-quick@wg0 || true
fi
if (( repair )); then
  if ! /usr/local/sbin/wg-normal-recover; then
    exit 0
  fi
fi

egress_ok=0
for url in https://api.ipify.org https://ip.sb https://ifconfig.me; do
  if curl -4 --connect-timeout 8 --max-time 20 -fsS "$url" >/dev/null 2>&1; then
    egress_ok=1
    break
  fi
done
if (( ! egress_ok )); then
  /usr/local/sbin/wg-normal-fallback "home IPv4 egress test failed"
  exit 0
fi
EOF
chmod 755 "$CHECK_BIN"

cat > "$RESTART_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl restart wg-quick@wg0
/usr/local/sbin/wg-normal-recover
wg show wg0 || true
systemctl status wg-quick@wg0 wg-normal-check.timer --no-pager --lines=8
EOF
chmod 755 "$RESTART_BIN"

cat > "$HELPER_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/wg-normal/config.env
case "${1:-status}" in
  status) echo "mode: $(cat "$MODE_FILE" 2>/dev/null || echo home)"; wg show wg0 || true; ip -4 rule show; ip -4 route show table "$WG_TABLE"; systemctl status wg-quick@wg0 wg-normal-check.timer --no-pager --lines=8 ;;
  check) /usr/local/sbin/wg-normal-check ;;
  apply) /usr/local/sbin/wg-normal-apply ;;
  fallback) /usr/local/sbin/wg-normal-fallback "manual fallback" ;;
  recover) /usr/local/sbin/wg-normal-recover ;;
  restart) /usr/local/bin/wg-normal-restart ;;
  stop|off) systemctl disable --now wg-normal-check.timer >/dev/null 2>&1 || true; /usr/local/sbin/wg-normal-fallback "manual stop"; systemctl stop wg-quick@wg0 >/dev/null 2>&1 || true; echo "已停止家宽出口策略路由和 wg0，当前使用本机原出口。" ;;
  start|on) systemctl enable --now wg-normal-check.timer >/dev/null 2>&1 || true; /usr/local/sbin/wg-normal-recover ;;
  logs) journalctl -u wg-quick@wg0 -u wg-normal-check.service --no-pager "${@:2}" ;;
  *) echo "usage: wg-normal status|check|apply|fallback|recover|restart|stop|start|logs" >&2; exit 2 ;;
esac
EOF
chmod 755 "$HELPER_BIN"

cat > "$CHECK_UNIT_FILE" <<EOF
[Unit]
Description=WireGuard normal VPS self-heal check
After=network-online.target wg-quick@wg0.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CHECK_BIN}
EOF

cat > "$CHECK_TIMER_FILE" <<'EOF'
[Unit]
Description=Run WireGuard normal VPS self-heal check

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=20s
Persistent=true

[Install]
WantedBy=timers.target
EOF

mkdir -p /etc/systemd/system/wg-quick@wg0.service.d
cat > /etc/systemd/system/wg-quick@wg0.service.d/10-incusse-normal-restart.conf <<'EOF'
[Service]
Restart=on-failure
RestartSec=5s
EOF

echo "==> 启动 WireGuard"
systemctl daemon-reload
systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
systemctl restart wg-quick@wg0
systemctl enable --now wg-normal-check.timer >/dev/null 2>&1 || true

sleep 2
echo
echo "==> 验证 (出口 IP 应为家宽 IP)"
NEW_IP="$(curl -4 -s --max-time 8 ifconfig.me | tr -d '\r\n' || echo '获取失败')"
echo "    当前出口 IP: $NEW_IP"
echo "    原公网 IP:   $PUB_IP"
if [[ "$NEW_IP" == "$PUB_IP" || "$NEW_IP" == "获取失败" ]]; then
  echo "    [!] 家宽出口暂不可用，已回落本机原出口；自修复会每 5 分钟尝试恢复家宽出口。"
  /usr/local/sbin/wg-normal-fallback "initial IPv4 egress test failed" || true
else
  echo "    [OK] IPv4 流量已走家宽出口"
  printf 'home\n' > "$MODE_FILE"
  chmod 600 "$MODE_FILE"
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
echo " 自修复:      wg-normal-check.timer 每 5 分钟检查；家宽不通自动回落本机出口"
echo "============================================================"
echo " 一键重启:    wg-normal-restart"
echo " 紧急停止:    sudo wg-normal stop"
echo " 排查:        wg-normal status | wg-normal logs -n 80"
echo " 提醒:        家宽动态 IP 建议填 DDNS 域名；填固定 IP 时无法自动发现新 IP。"
echo "============================================================"
