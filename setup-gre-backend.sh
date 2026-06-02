#!/usr/bin/env bash
# 普通 Incus 节点 GRE 后端脚本
# 运行位置: 普通线路机器，小鸡创建在这里。
# 作用: 建立 GRE 到优化线路节点，让小鸡出入口走优化节点，宿主机自身保持原线路。
# 用法:
#   sudo bash setup-gre-backend.sh
#   sudo GATEWAY_PUBLIC_IP=1.2.3.4 GUEST_SUBNET=10.10.0.0/22 bash setup-gre-backend.sh
set -euo pipefail
trap 'echo "[ERROR] 脚本在第 ${LINENO} 行退出: ${BASH_COMMAND}" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "需要 root 权限 (sudo)"; exit 1; }
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu"; exit 1; }

STATE_DIR="/etc/gre-backend"
CONFIG_FILE="$STATE_DIR/config.env"
APPLY_BIN="/usr/local/sbin/gre-backend-apply"
UNIT_FILE="/etc/systemd/system/gre-backend.service"

GRE_NAME="${GRE_NAME:-gre-opt}"
GRE_TABLE="${GRE_TABLE:-2010}"
GRE_RULE_PREF="${GRE_RULE_PREF:-2010}"
GATEWAY_TUN_IP="${GATEWAY_TUN_IP:-10.255.0.1}"
BACKEND_TUN_IP="${BACKEND_TUN_IP:-10.255.0.2}"
GRE_MTU="${GRE_MTU:-1476}"
TCP_MSS="${TCP_MSS:-1436}"
GUEST_SUBNET="${GUEST_SUBNET:-10.10.0.0/22}"
INCUS_BRIDGE="${INCUS_BRIDGE:-incusbr0}"
GATEWAY_PUBLIC_IP="${GATEWAY_PUBLIC_IP:-}"
BACKEND_PUBLIC_IP="${BACKEND_PUBLIC_IP:-}"

if [[ -z "$GATEWAY_PUBLIC_IP" ]]; then
  read -rp "优化线路节点公网 IPv4/域名: " GATEWAY_PUBLIC_IP
fi
[[ -n "$GATEWAY_PUBLIC_IP" && "$GATEWAY_PUBLIC_IP" != *:* ]] || { echo "优化节点地址无效，只支持 IPv4 或 A 记录域名"; exit 1; }

echo "==> 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq iproute2 iptables curl ca-certificates

WAN_IF="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
[[ -n "$WAN_IF" ]] || { echo "无法识别默认出口网卡"; exit 1; }

if [[ -z "$BACKEND_PUBLIC_IP" ]]; then
  BACKEND_PUBLIC_IP="$(ip -4 -o addr show dev "$WAN_IF" scope global | awk '{split($4,a,"/"); print a[1]; exit}')"
fi
[[ -n "$BACKEND_PUBLIC_IP" ]] || { echo "无法识别普通节点本机 IPv4"; exit 1; }

GATEWAY_RESOLVED_IP="$GATEWAY_PUBLIC_IP"
if [[ ! "$GATEWAY_PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  GATEWAY_RESOLVED_IP="$(getent ahostsv4 "$GATEWAY_PUBLIC_IP" | awk '{print $1; exit}')"
fi
[[ -n "$GATEWAY_RESOLVED_IP" ]] || { echo "无法解析优化节点 IPv4: $GATEWAY_PUBLIC_IP"; exit 1; }

echo "==> 写入配置"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
cat > "$CONFIG_FILE" <<EOF
GRE_NAME=${GRE_NAME}
WAN_IF=${WAN_IF}
BACKEND_PUBLIC_IP=${BACKEND_PUBLIC_IP}
GATEWAY_PUBLIC_IP=${GATEWAY_RESOLVED_IP}
GATEWAY_TUN_IP=${GATEWAY_TUN_IP}
BACKEND_TUN_IP=${BACKEND_TUN_IP}
GRE_MTU=${GRE_MTU}
TCP_MSS=${TCP_MSS}
GUEST_SUBNET=${GUEST_SUBNET}
INCUS_BRIDGE=${INCUS_BRIDGE}
GRE_TABLE=${GRE_TABLE}
GRE_RULE_PREF=${GRE_RULE_PREF}
EOF
chmod 600 "$CONFIG_FILE"

cat > "$APPLY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gre-backend/config.env

sysctl -w net.ipv4.ip_forward=1 >/dev/null
cat > /etc/sysctl.d/99-gre-backend.conf <<SYSCTL
net.ipv4.ip_forward=1
SYSCTL

ip tunnel del "$GRE_NAME" 2>/dev/null || true
ip tunnel add "$GRE_NAME" mode gre local "$BACKEND_PUBLIC_IP" remote "$GATEWAY_PUBLIC_IP" ttl 255
ip addr add "${BACKEND_TUN_IP}/30" dev "$GRE_NAME"
ip link set "$GRE_NAME" mtu "$GRE_MTU" up

ip route replace "$GUEST_SUBNET" dev "$INCUS_BRIDGE" table "$GRE_TABLE"
ip route replace default via "$GATEWAY_TUN_IP" dev "$GRE_NAME" table "$GRE_TABLE"
ip rule del from "$GUEST_SUBNET" table "$GRE_TABLE" pref "$GRE_RULE_PREF" 2>/dev/null || true
ip rule add from "$GUEST_SUBNET" table "$GRE_TABLE" pref "$GRE_RULE_PREF"
ip route flush cache 2>/dev/null || true

iptables -C INPUT -p 47 -s "$GATEWAY_PUBLIC_IP" -j ACCEPT 2>/dev/null || iptables -I INPUT -p 47 -s "$GATEWAY_PUBLIC_IP" -j ACCEPT
iptables -C FORWARD -i "$INCUS_BRIDGE" -o "$GRE_NAME" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$INCUS_BRIDGE" -o "$GRE_NAME" -j ACCEPT
iptables -C FORWARD -i "$GRE_NAME" -o "$INCUS_BRIDGE" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$GRE_NAME" -o "$INCUS_BRIDGE" -j ACCEPT
iptables -t nat -C POSTROUTING -s "$GUEST_SUBNET" -o "$GRE_NAME" -j RETURN 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s "$GUEST_SUBNET" -o "$GRE_NAME" -j RETURN
iptables -t mangle -C FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TCP_MSS" 2>/dev/null || iptables -t mangle -A FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TCP_MSS"
iptables -t mangle -C FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TCP_MSS" 2>/dev/null || iptables -t mangle -A FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TCP_MSS"
EOF
chmod +x "$APPLY_BIN"

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=GRE backend for optimized gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${APPLY_BIN}

[Install]
WantedBy=multi-user.target
EOF

echo "==> 启动 GRE 后端"
systemctl daemon-reload
systemctl enable --now gre-backend.service

echo
echo "============================================================"
echo " GRE 普通节点后端配置完成"
echo "------------------------------------------------------------"
echo " 普通节点公网: ${BACKEND_PUBLIC_IP}"
echo " 优化节点公网: ${GATEWAY_RESOLVED_IP}"
echo " GRE:          ${BACKEND_TUN_IP}/30 -> ${GATEWAY_TUN_IP}/30"
echo " 小鸡网段:     ${GUEST_SUBNET}"
echo " Incus Bridge: ${INCUS_BRIDGE}"
echo " MTU/MSS:      MTU ${GRE_MTU}, TCP MSS ${TCP_MSS}"
echo "------------------------------------------------------------"
echo " 检查:"
echo "   ip addr show ${GRE_NAME}"
echo "   ip rule show | grep ${GRE_TABLE}"
echo "   ping -c 3 ${GATEWAY_TUN_IP}"
echo "============================================================"
