#!/usr/bin/env bash
# WireGuard 优化线路后端脚本
# 运行位置: 普通 Incus 节点，小鸡创建在这里。
# 作用: 使用 WireGuard 到优化线路节点，让小鸡出入口走优化节点，宿主机自身保持原线路。
set -euo pipefail
trap 'echo "[ERROR] 脚本在第 ${LINENO} 行退出: ${BASH_COMMAND}" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "需要 root 权限 (sudo)"; exit 1; }
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu"; exit 1; }

STATE_DIR="/etc/wg-backend"
CONFIG_FILE="$STATE_DIR/config.env"
APPLY_BIN="/usr/local/sbin/wg-backend-apply"
REMOVE_BIN="/usr/local/sbin/wg-backend-remove"
HELPER_BIN="/usr/local/bin/wg-be"
UNIT_FILE="/etc/systemd/system/wg-backend.service"

WG_NAME="${WG_NAME:-wg-opt}"
WG_MTU="${WG_MTU:-1180}"
WG_TABLE="${WG_TABLE:-2020}"
WG_RULE_PREF="${WG_RULE_PREF:-2020}"
GATEWAY_TUN_IP="${GATEWAY_TUN_IP:-10.255.10.1}"
BACKEND_TUN_IP="${BACKEND_TUN_IP:-10.255.10.2}"
GUEST_SUBNET="${GUEST_SUBNET:-}"
INCUS_BRIDGE="${INCUS_BRIDGE:-}"
GATEWAY_PUBLIC_IP="${GATEWAY_PUBLIC_IP:-}"
GATEWAY_PORT="${GATEWAY_PORT:-51820}"
GATEWAY_PUBLIC_KEY="${GATEWAY_PUBLIC_KEY:-}"
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
  local log_file="/tmp/wg-backend-apt-update.log"
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

if [[ -z "$INCUS_BRIDGE" ]]; then
  echo "Incus bridge 说明: 通常是 incusbr0。小鸡网段来自这个网桥。"
  read -rp "Incus bridge 名称 [incusbr0]: " INCUS_BRIDGE
  INCUS_BRIDGE="${INCUS_BRIDGE:-incusbr0}"
fi

if [[ -z "$GUEST_SUBNET" ]]; then
  echo "小鸡网段说明: 填 ${INCUS_BRIDGE} 的 IPv4 CIDR，例如 10.10.0.0/22。"
  read -rp "小鸡/Incus bridge 网段 [10.10.0.0/22]: " GUEST_SUBNET
  GUEST_SUBNET="${GUEST_SUBNET:-10.10.0.0/22}"
fi
normalize_guest_subnet

echo "==> 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt_update_with_repair
apt-get install -y -qq wireguard iproute2 iptables curl ca-certificates

echo "==> 停止旧 GRE 后端，避免路由/防火墙冲突"
systemctl disable --now gre-backend.service >/dev/null 2>&1 || true

echo "==> 生成 WireGuard 密钥"
mkdir -p /etc/wireguard "$STATE_DIR"
chmod 700 /etc/wireguard "$STATE_DIR"
umask 077
[[ -f "/etc/wireguard/${WG_NAME}-backend.key" ]] || wg genkey | tee "/etc/wireguard/${WG_NAME}-backend.key" | wg pubkey > "/etc/wireguard/${WG_NAME}-backend.pub"
BACKEND_PUBLIC_KEY="$(cat "/etc/wireguard/${WG_NAME}-backend.pub")"

echo
echo "============================================================"
echo " 普通节点 WireGuard 公钥，粘贴到优化线路网关脚本:"
echo "   ${BACKEND_PUBLIC_KEY}"
echo "============================================================"
echo

if [[ -z "$GATEWAY_PUBLIC_IP" ]]; then
  read -rp "优化线路节点公网 IPv4/域名；暂时没有可直接回车退出: " GATEWAY_PUBLIC_IP
fi
if [[ -z "$GATEWAY_PUBLIC_IP" ]]; then
  echo "已生成普通节点公钥。请先到优化线路节点运行 setup-wg-gateway.sh 并粘贴该公钥。"
  exit 0
fi
if [[ -z "$GATEWAY_PUBLIC_KEY" ]]; then
  read -rp "优化线路网关 WireGuard 公钥: " GATEWAY_PUBLIC_KEY
fi
[[ -n "$GATEWAY_PUBLIC_KEY" ]] || { echo "网关公钥不能为空"; exit 1; }
valid_port "$GATEWAY_PORT" || { echo "WireGuard 网关端口无效: $GATEWAY_PORT"; exit 1; }

if [[ "$GATEWAY_PUBLIC_IP" == *:* ]]; then
  echo "只支持 IPv4 Endpoint，请输入 IPv4 地址或解析到 A 记录的域名"
  exit 1
fi
if [[ "$GATEWAY_PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  GATEWAY_ENDPOINT_IP="$GATEWAY_PUBLIC_IP"
else
  GATEWAY_ENDPOINT_IP="$(getent ahostsv4 "$GATEWAY_PUBLIC_IP" | awk '{print $1; exit}')"
fi
[[ -n "$GATEWAY_ENDPOINT_IP" ]] || { echo "无法解析优化线路节点 IPv4: $GATEWAY_PUBLIC_IP"; exit 1; }

echo "==> 写入 WireGuard 配置"
cat > "/etc/wireguard/${WG_NAME}.conf" <<EOF
[Interface]
Address = ${BACKEND_TUN_IP}/30
PrivateKey = $(cat "/etc/wireguard/${WG_NAME}-backend.key")
Table = off
MTU = ${WG_MTU}

[Peer]
PublicKey = ${GATEWAY_PUBLIC_KEY}
Endpoint = ${GATEWAY_ENDPOINT_IP}:${GATEWAY_PORT}
AllowedIPs = ${GATEWAY_TUN_IP}/32, 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 "/etc/wireguard/${WG_NAME}.conf"

cat > "$CONFIG_FILE" <<EOF
WG_NAME=${WG_NAME}
GATEWAY_PUBLIC_IP=${GATEWAY_ENDPOINT_IP}
GATEWAY_TUN_IP=${GATEWAY_TUN_IP}
BACKEND_TUN_IP=${BACKEND_TUN_IP}
GUEST_SUBNET=${GUEST_SUBNET}
INCUS_BRIDGE=${INCUS_BRIDGE}
WG_TABLE=${WG_TABLE}
WG_RULE_PREF=${WG_RULE_PREF}
PREFORWARD_ENABLE=${PREFORWARD_ENABLE}
PREFORWARD_RANGE=${PREFORWARD_RANGE}
EOF
chmod 600 "$CONFIG_FILE"

cat > "$APPLY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/wg-backend/config.env

sysctl -w net.ipv4.ip_forward=1 >/dev/null
cat > /etc/sysctl.d/99-wg-backend.conf <<SYSCTL
net.ipv4.ip_forward=1
SYSCTL

systemctl start "wg-quick@${WG_NAME}.service"

ip route replace "$GUEST_SUBNET" dev "$INCUS_BRIDGE" table "$WG_TABLE"
ip route replace default via "$GATEWAY_TUN_IP" dev "$WG_NAME" table "$WG_TABLE"
ip rule del from "$GUEST_SUBNET" table "$WG_TABLE" pref "$WG_RULE_PREF" 2>/dev/null || true
ip rule add from "$GUEST_SUBNET" table "$WG_TABLE" pref "$WG_RULE_PREF"
ip rule del from "$BACKEND_TUN_IP" table "$WG_TABLE" pref "$((WG_RULE_PREF + 1))" 2>/dev/null || true
ip rule add from "$BACKEND_TUN_IP" table "$WG_TABLE" pref "$((WG_RULE_PREF + 1))"
ip route flush cache 2>/dev/null || true

while iptables -t mangle -D FORWARD -o "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
while iptables -t mangle -D FORWARD -i "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
iptables -t mangle -A FORWARD -o "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -A FORWARD -i "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

iptables -C FORWARD -i "$INCUS_BRIDGE" -o "$WG_NAME" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$INCUS_BRIDGE" -o "$WG_NAME" -j ACCEPT
iptables -C FORWARD -i "$WG_NAME" -o "$INCUS_BRIDGE" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$WG_NAME" -o "$INCUS_BRIDGE" -j ACCEPT
iptables -t nat -C POSTROUTING -s "$GUEST_SUBNET" -o "$WG_NAME" -j RETURN 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s "$GUEST_SUBNET" -o "$WG_NAME" -j RETURN

if [[ "${PREFORWARD_ENABLE:-1}" == "1" ]]; then
  for proto in tcp udp; do
    comment="WG-BE-RANGE ${proto}:${PREFORWARD_RANGE}"
    iptables -C INPUT -i "$WG_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -i "$WG_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT
  done
fi
EOF
chmod +x "$APPLY_BIN"

cat > "$REMOVE_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/wg-backend/config.env

while iptables -t mangle -D FORWARD -o "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
while iptables -t mangle -D FORWARD -i "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
while iptables -t nat -D POSTROUTING -s "$GUEST_SUBNET" -o "$WG_NAME" -j RETURN 2>/dev/null; do :; done
for proto in tcp udp; do
  comment="WG-BE-RANGE ${proto}:${PREFORWARD_RANGE}"
  while iptables -D INPUT -i "$WG_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; do :; done
done
while iptables -D FORWARD -i "$WG_NAME" -o "$INCUS_BRIDGE" -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -i "$INCUS_BRIDGE" -o "$WG_NAME" -j ACCEPT 2>/dev/null; do :; done
ip rule del from "$BACKEND_TUN_IP" table "$WG_TABLE" pref "$((WG_RULE_PREF + 1))" 2>/dev/null || true
ip rule del from "$GUEST_SUBNET" table "$WG_TABLE" pref "$WG_RULE_PREF" 2>/dev/null || true
ip route flush table "$WG_TABLE" 2>/dev/null || true
ip route flush cache 2>/dev/null || true
systemctl stop "wg-quick@${WG_NAME}.service" 2>/dev/null || true
EOF
chmod +x "$REMOVE_BIN"

cat > "$HELPER_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/wg-backend/config.env

usage() {
  cat <<USAGE
用法:
  sudo wg-be on
  sudo wg-be off
  sudo wg-be restart
  sudo wg-be status
USAGE
}

case "${1:-}" in
  on|enable|start) systemctl enable --now wg-backend.service ;;
  off|disable|stop) systemctl disable --now wg-backend.service ;;
  restart) systemctl restart wg-backend.service ;;
  status)
    systemctl is-active wg-backend.service 2>/dev/null || true
    wg show "$WG_NAME" 2>/dev/null || true
    ip rule show | grep -F "lookup ${WG_TABLE}" || true
    ip route show table "$WG_TABLE" 2>/dev/null || true
    ;;
  *) usage; exit 1 ;;
esac
EOF
chmod +x "$HELPER_BIN"

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=WireGuard backend for optimized gateway
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

echo "==> 启动 WireGuard 后端"
systemctl daemon-reload
systemctl enable "wg-quick@${WG_NAME}.service" >/dev/null
systemctl enable wg-backend.service >/dev/null
systemctl restart wg-backend.service

echo
echo "============================================================"
echo " WireGuard 普通节点后端配置完成"
echo "------------------------------------------------------------"
echo " 优化节点:     ${GATEWAY_ENDPOINT_IP}:${GATEWAY_PORT}"
echo " WireGuard:    ${BACKEND_TUN_IP}/30 -> ${GATEWAY_TUN_IP}/30"
echo " 小鸡网段:     ${GUEST_SUBNET}"
echo " Incus Bridge: ${INCUS_BRIDGE}"
echo " MTU:          ${WG_MTU}"
echo " 预转发端口:   ${PREFORWARD_ENABLE} (${PREFORWARD_RANGE})"
echo "------------------------------------------------------------"
echo " 管理:"
echo "   sudo wg-be status"
echo "   sudo wg-be off"
echo "   sudo wg-be on"
echo " 测试:"
echo "   ping -c 3 ${GATEWAY_TUN_IP}"
echo "============================================================"
