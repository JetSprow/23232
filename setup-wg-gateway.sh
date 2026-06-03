#!/usr/bin/env bash
# WireGuard 优化线路网关脚本
# 运行位置: 优化线路机器
# 作用: 使用 WireGuard 连接普通 Incus 节点，负责小鸡出口 SNAT 和公网端口预转发。
set -euo pipefail
trap 'echo "[ERROR] 脚本在第 ${LINENO} 行退出: ${BASH_COMMAND}" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "需要 root 权限 (sudo)"; exit 1; }
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu"; exit 1; }

STATE_DIR="/etc/wg-gateway"
CONFIG_FILE="$STATE_DIR/config.env"
APPLY_BIN="/usr/local/sbin/wg-gateway-apply"
REMOVE_BIN="/usr/local/sbin/wg-gateway-remove"
HELPER_BIN="/usr/local/bin/wg-gw"
UNIT_FILE="/etc/systemd/system/wg-gateway.service"

WG_NAME="${WG_NAME:-wg-opt}"
WG_PORT="${WG_PORT:-51820}"
WG_MTU="${WG_MTU:-1180}"
GATEWAY_TUN_IP="${GATEWAY_TUN_IP:-10.255.10.1}"
BACKEND_TUN_IP="${BACKEND_TUN_IP:-10.255.10.2}"
GUEST_SUBNET="${GUEST_SUBNET:-}"
BACKEND_PUBLIC_KEY="${BACKEND_PUBLIC_KEY:-}"
GATEWAY_PUBLIC_IP="${GATEWAY_PUBLIC_IP:-}"
WAN_IF="${WAN_IF:-}"
PREFORWARD_ENABLE="${PREFORWARD_ENABLE:-1}"
PREFORWARD_RANGE="${PREFORWARD_RANGE:-20000:30000}"

normalize_cidr() {
  local cidr="$1" ip prefix a b c d ipnum mask net
  if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    echo "CIDR 格式无效: $cidr" >&2
    return 1
  fi
  ip="${cidr%/*}"
  prefix="${cidr#*/}"
  IFS=. read -r a b c d <<<"$ip"
  for part in "$a" "$b" "$c" "$d"; do
    if ((part < 0 || part > 255)); then
      echo "CIDR 地址段超出范围: $cidr" >&2
      return 1
    fi
  done
  if ((prefix < 0 || prefix > 32)); then
    echo "CIDR 掩码超出范围: $cidr" >&2
    return 1
  fi
  ipnum=$(((a << 24) | (b << 16) | (c << 8) | d))
  if ((prefix == 0)); then
    mask=0
  else
    mask=$(((0xffffffff << (32 - prefix)) & 0xffffffff))
  fi
  net=$((ipnum & mask))
  printf "%d.%d.%d.%d/%d\n" "$(((net >> 24) & 255))" "$(((net >> 16) & 255))" "$(((net >> 8) & 255))" "$((net & 255))" "$prefix"
}

normalize_guest_subnet() {
  local normalized
  normalized="$(normalize_cidr "$GUEST_SUBNET")" || exit 1
  if [[ "$normalized" != "$GUEST_SUBNET" ]]; then
    echo "小鸡网段已规范化: ${GUEST_SUBNET} -> ${normalized}"
  fi
  GUEST_SUBNET="$normalized"
}

disable_broken_backports_repo() {
  local file
  echo "==> 检测到 bullseye-backports 源不可用，自动禁用后重试"
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    grep -qi 'bullseye-backports' "$file" || continue
    cp -n "$file" "${file}.bak" 2>/dev/null || true
    case "$file" in
      *.sources) mv "$file" "${file}.disabled"; echo "   disabled: ${file}" ;;
      *) sed -i '/bullseye-backports/s/^[[:space:]]*\(deb\|deb-src\)[[:space:]]/# disabled by wg setup: &/' "$file"; echo "   patched:  ${file}" ;;
    esac
  done < <(find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) 2>/dev/null)
}

apt_update_with_repair() {
  local log_file="/tmp/wg-gateway-apt-update.log"
  if apt-get update -qq >"$log_file" 2>&1; then
    rm -f "$log_file"
    return 0
  fi
  if grep -qi 'bullseye-backports.*Release file' "$log_file"; then
    cat "$log_file" >&2
    disable_broken_backports_repo
    apt-get update -qq
    rm -f "$log_file"
    return 0
  fi
  cat "$log_file" >&2
  rm -f "$log_file"
  return 1
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

if [[ -z "$GUEST_SUBNET" ]]; then
  echo "小鸡网段说明: 填普通 Incus 节点 incusbr0 正在使用的 IPv4 网段，不是小鸡内网 IP。"
  read -rp "小鸡/Incus bridge 网段 [10.10.0.0/22]: " GUEST_SUBNET
  GUEST_SUBNET="${GUEST_SUBNET:-10.10.0.0/22}"
fi
normalize_guest_subnet

if ! valid_port "$WG_PORT"; then
  echo "WireGuard 端口无效: $WG_PORT"
  exit 1
fi

echo "==> 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt_update_with_repair
apt-get install -y -qq wireguard iproute2 iptables curl ca-certificates

echo "==> 停止旧 GRE 网关，避免路由/防火墙冲突"
systemctl disable --now gre-gateway.service >/dev/null 2>&1 || true
ip route del "$GUEST_SUBNET" via 10.255.0.2 dev gre-incus 2>/dev/null || true
ip tunnel del gre-incus 2>/dev/null || true
for proto in tcp udp; do
  while iptables -t nat -D PREROUTING -p "$proto" --dport "$PREFORWARD_RANGE" -j DNAT --to-destination 10.255.0.2 2>/dev/null; do :; done
done

WAN_IF="${WAN_IF:-$(ip -4 route show default | awk '/default/ {print $5; exit}')}"
[[ -n "$WAN_IF" ]] || { echo "无法识别默认出口网卡"; exit 1; }

if [[ -z "$GATEWAY_PUBLIC_IP" ]]; then
  GATEWAY_PUBLIC_IP="$(ip -4 -o addr show dev "$WAN_IF" scope global | awk '{split($4,a,"/"); print a[1]; exit}')"
fi
[[ -n "$GATEWAY_PUBLIC_IP" ]] || { echo "无法识别优化节点本机 IPv4"; exit 1; }

echo "==> 生成 WireGuard 密钥"
mkdir -p /etc/wireguard "$STATE_DIR"
chmod 700 /etc/wireguard "$STATE_DIR"
umask 077
[[ -f "/etc/wireguard/${WG_NAME}-gateway.key" ]] || wg genkey | tee "/etc/wireguard/${WG_NAME}-gateway.key" | wg pubkey > "/etc/wireguard/${WG_NAME}-gateway.pub"
GATEWAY_PUBLIC_KEY="$(cat "/etc/wireguard/${WG_NAME}-gateway.pub")"

echo
echo "============================================================"
echo " 优化线路网关 WireGuard 公钥，粘贴到普通节点脚本:"
echo "   ${GATEWAY_PUBLIC_KEY}"
echo "============================================================"
echo

if [[ -z "$BACKEND_PUBLIC_KEY" ]]; then
  read -rp "粘贴普通节点 WireGuard 公钥；暂时没有可直接回车退出: " BACKEND_PUBLIC_KEY
fi
if [[ -z "$BACKEND_PUBLIC_KEY" ]]; then
  echo "已生成网关公钥。请先到普通节点运行 setup-wg-backend.sh 获取普通节点公钥。"
  exit 0
fi

echo "==> 写入 WireGuard 配置"
cat > "/etc/wireguard/${WG_NAME}.conf" <<EOF
[Interface]
Address = ${GATEWAY_TUN_IP}/30
ListenPort = ${WG_PORT}
PrivateKey = $(cat "/etc/wireguard/${WG_NAME}-gateway.key")
Table = off
MTU = ${WG_MTU}

[Peer]
PublicKey = ${BACKEND_PUBLIC_KEY}
AllowedIPs = ${BACKEND_TUN_IP}/32, ${GUEST_SUBNET}
EOF
chmod 600 "/etc/wireguard/${WG_NAME}.conf"

cat > "$CONFIG_FILE" <<EOF
WG_NAME=${WG_NAME}
WG_PORT=${WG_PORT}
WAN_IF=${WAN_IF}
GATEWAY_PUBLIC_IP=${GATEWAY_PUBLIC_IP}
GATEWAY_TUN_IP=${GATEWAY_TUN_IP}
BACKEND_TUN_IP=${BACKEND_TUN_IP}
GUEST_SUBNET=${GUEST_SUBNET}
PREFORWARD_ENABLE=${PREFORWARD_ENABLE}
PREFORWARD_RANGE=${PREFORWARD_RANGE}
EOF
chmod 600 "$CONFIG_FILE"

cat > "$APPLY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/wg-gateway/config.env

sysctl -w net.ipv4.ip_forward=1 >/dev/null
cat > /etc/sysctl.d/99-wg-gateway.conf <<SYSCTL
net.ipv4.ip_forward=1
SYSCTL

systemctl start "wg-quick@${WG_NAME}.service"
ip route replace "$GUEST_SUBNET" via "$BACKEND_TUN_IP" dev "$WG_NAME"

while iptables -t mangle -D FORWARD -o "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
while iptables -t mangle -D FORWARD -i "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
iptables -t mangle -A FORWARD -o "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -A FORWARD -i "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

iptables -C INPUT -p udp --dport "$WG_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$WG_PORT" -j ACCEPT
iptables -C FORWARD -i "$WG_NAME" -o "$WAN_IF" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$WG_NAME" -o "$WAN_IF" -j ACCEPT
iptables -C FORWARD -i "$WAN_IF" -o "$WG_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$WAN_IF" -o "$WG_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -C POSTROUTING -s "$GUEST_SUBNET" -o "$WAN_IF" -j SNAT --to-source "$GATEWAY_PUBLIC_IP" 2>/dev/null || iptables -t nat -A POSTROUTING -s "$GUEST_SUBNET" -o "$WAN_IF" -j SNAT --to-source "$GATEWAY_PUBLIC_IP"

if [[ "${PREFORWARD_ENABLE:-1}" == "1" ]]; then
  for proto in tcp udp; do
    comment="WG-GW-RANGE ${proto}:${PREFORWARD_RANGE}->${BACKEND_TUN_IP}"
    iptables -t nat -C PREROUTING -i "$WAN_IF" -p "$proto" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j DNAT --to-destination "$BACKEND_TUN_IP" 2>/dev/null || \
      iptables -t nat -A PREROUTING -i "$WAN_IF" -p "$proto" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j DNAT --to-destination "$BACKEND_TUN_IP"
    iptables -C FORWARD -i "$WAN_IF" -o "$WG_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || \
      iptables -A FORWARD -i "$WAN_IF" -o "$WG_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT
  done
fi
EOF
chmod +x "$APPLY_BIN"

cat > "$REMOVE_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/wg-gateway/config.env

while iptables -t mangle -D FORWARD -o "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
while iptables -t mangle -D FORWARD -i "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
for proto in tcp udp; do
  comment="WG-GW-RANGE ${proto}:${PREFORWARD_RANGE}->${BACKEND_TUN_IP}"
  while iptables -t nat -D PREROUTING -i "$WAN_IF" -p "$proto" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j DNAT --to-destination "$BACKEND_TUN_IP" 2>/dev/null; do :; done
  while iptables -D FORWARD -i "$WAN_IF" -o "$WG_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; do :; done
done
while iptables -t nat -D POSTROUTING -s "$GUEST_SUBNET" -o "$WAN_IF" -j SNAT --to-source "$GATEWAY_PUBLIC_IP" 2>/dev/null; do :; done
while iptables -D FORWARD -i "$WAN_IF" -o "$WG_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -i "$WG_NAME" -o "$WAN_IF" -j ACCEPT 2>/dev/null; do :; done
while iptables -D INPUT -p udp --dport "$WG_PORT" -j ACCEPT 2>/dev/null; do :; done
ip route del "$GUEST_SUBNET" via "$BACKEND_TUN_IP" dev "$WG_NAME" 2>/dev/null || true
systemctl stop "wg-quick@${WG_NAME}.service" 2>/dev/null || true
EOF
chmod +x "$REMOVE_BIN"

cat > "$HELPER_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/wg-gateway/config.env

usage() {
  cat <<USAGE
用法:
  sudo wg-gw on
  sudo wg-gw off
  sudo wg-gw restart
  sudo wg-gw status
  sudo wg-gw list
USAGE
}

case "${1:-}" in
  on|enable|start) systemctl enable --now wg-gateway.service ;;
  off|disable|stop) systemctl disable --now wg-gateway.service ;;
  restart) systemctl restart wg-gateway.service ;;
  status)
    systemctl is-active wg-gateway.service 2>/dev/null || true
    wg show "$WG_NAME" 2>/dev/null || true
    ip route show "$GUEST_SUBNET" 2>/dev/null || true
    iptables -t nat -S PREROUTING | grep -E 'WG-GW|WG-GW-RANGE' || true
    ;;
  list) iptables -t nat -S PREROUTING | grep -E 'WG-GW|WG-GW-RANGE' || true ;;
  *) usage; exit 1 ;;
esac
EOF
chmod +x "$HELPER_BIN"

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=WireGuard optimized gateway
After=network-online.target wg-quick@${WG_NAME}.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${APPLY_BIN}
ExecStop=${REMOVE_BIN}

[Install]
WantedBy=multi-user.target
EOF

echo "==> 启动 WireGuard 网关"
systemctl daemon-reload
systemctl enable "wg-quick@${WG_NAME}.service" >/dev/null
systemctl enable wg-gateway.service >/dev/null
systemctl restart wg-gateway.service

echo
echo "============================================================"
echo " WireGuard 优化线路网关配置完成"
echo "------------------------------------------------------------"
echo " 优化节点公网: ${GATEWAY_PUBLIC_IP}"
echo " WireGuard:    UDP ${WG_PORT}, ${GATEWAY_TUN_IP}/30 -> ${BACKEND_TUN_IP}/30"
echo " 小鸡网段:     ${GUEST_SUBNET}"
echo " MTU:          ${WG_MTU}"
echo " 预转发端口:   ${PREFORWARD_ENABLE} (${PREFORWARD_RANGE})"
echo "------------------------------------------------------------"
echo " 普通节点接入参数:"
echo "   网关地址: ${GATEWAY_PUBLIC_IP}"
echo "   网关端口: ${WG_PORT}"
echo "   网关公钥: ${GATEWAY_PUBLIC_KEY}"
echo "------------------------------------------------------------"
echo " 管理:"
echo "   sudo wg-gw status"
echo "   sudo wg-gw off"
echo "   sudo wg-gw on"
echo "============================================================"
