#!/usr/bin/env bash
# A 入口机脚本：用户访问 A 公网端口，A 通过 WireGuard 隧道转发到 B。
# 拓扑: 用户 -> A:20000-30000 -> wg-ab -> B:同端口 -> C:同端口 -> 小鸡
set -euo pipefail
trap 'echo "[ERROR] 脚本在第 ${LINENO} 行退出: ${BASH_COMMAND}" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "需要 root 权限 (sudo)"; exit 1; }
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu"; exit 1; }

STATE_DIR="/etc/ab-entry"
CONFIG_FILE="$STATE_DIR/config.env"
APPLY_BIN="/usr/local/sbin/ab-entry-apply"
REMOVE_BIN="/usr/local/sbin/ab-entry-remove"
CHECK_BIN="/usr/local/sbin/ab-entry-check"
HELPER_BIN="/usr/local/bin/ab-entry"
RESTART_BIN="/usr/local/bin/ab-entry-restart"
UNIT_FILE="/etc/systemd/system/ab-entry.service"
CHECK_UNIT_FILE="/etc/systemd/system/ab-entry-check.service"
CHECK_TIMER_FILE="/etc/systemd/system/ab-entry-check.timer"

WG_NAME="${WG_NAME:-wg-ab}"
WG_PORT="${WG_PORT:-51821}"
WG_MTU="${WG_MTU:-1280}"
ENTRY_TUN_IP="${ENTRY_TUN_IP:-10.66.0.1}"
RELAY_TUN_IP="${RELAY_TUN_IP:-10.66.0.2}"
B_PUBLIC_KEY="${B_PUBLIC_KEY:-}"
PREFORWARD_RANGE="${PREFORWARD_RANGE:-20000:30000}"
WAN_IF="${WAN_IF:-}"
ENTRY_PUBLIC_IP="${ENTRY_PUBLIC_IP:-}"

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

valid_range() {
  local low="${1%:*}" high="${1#*:}"
  valid_port "$low" && valid_port "$high" && (( low <= high ))
}

apt_update_with_repair() {
  local log_file="/tmp/ab-entry-apt-update.log"
  if apt-get update -qq >"$log_file" 2>&1; then
    rm -f "$log_file"
    return 0
  fi
  if grep -qi 'bullseye-backports.*Release file' "$log_file"; then
    cat "$log_file" >&2
    find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) 2>/dev/null | while read -r file; do
      grep -qi 'bullseye-backports' "$file" || continue
      cp -n "$file" "${file}.bak" 2>/dev/null || true
      case "$file" in
        *.sources) mv "$file" "${file}.disabled" ;;
        *) sed -i '/bullseye-backports/s/^[[:space:]]*\(deb\|deb-src\)[[:space:]]/# disabled by ab-entry setup: &/' "$file" ;;
      esac
    done
    apt-get update -qq
    rm -f "$log_file"
    return 0
  fi
  cat "$log_file" >&2
  rm -f "$log_file"
  return 1
}

valid_port "$WG_PORT" || { echo "WireGuard 端口无效: $WG_PORT"; exit 1; }
valid_range "$PREFORWARD_RANGE" || { echo "端口范围无效，应类似 20000:30000"; exit 1; }

echo "==> 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt_update_with_repair
apt-get install -y -qq wireguard iproute2 iptables curl ca-certificates

WAN_IF="${WAN_IF:-$(ip -4 route show default | awk '/default/ {print $5; exit}')}"
[[ -n "$WAN_IF" ]] || { echo "无法识别默认出口网卡"; exit 1; }
ENTRY_PUBLIC_IP="${ENTRY_PUBLIC_IP:-$(ip -4 -o addr show dev "$WAN_IF" scope global | awk '{split($4,a,"/"); print a[1]; exit}')}"

echo "==> 生成 WireGuard 密钥"
mkdir -p /etc/wireguard "$STATE_DIR"
chmod 700 /etc/wireguard "$STATE_DIR"
umask 077
[[ -f "/etc/wireguard/${WG_NAME}-entry.key" ]] || wg genkey | tee "/etc/wireguard/${WG_NAME}-entry.key" | wg pubkey > "/etc/wireguard/${WG_NAME}-entry.pub"
ENTRY_PUBLIC_KEY="$(cat "/etc/wireguard/${WG_NAME}-entry.pub")"

echo
echo "============================================================"
echo " A 入口机 WireGuard 公钥，粘贴到 B 中继脚本:"
echo "   ${ENTRY_PUBLIC_KEY}"
echo "============================================================"
echo

if [[ -z "$B_PUBLIC_KEY" ]]; then
  read -rp "粘贴 B 中继机 WireGuard 公钥；暂时没有可直接回车退出: " B_PUBLIC_KEY
fi
if [[ -z "$B_PUBLIC_KEY" ]]; then
  echo "已生成 A 公钥。请到 B 运行 setup-ab-relay.sh，拿到 B 公钥后再回来运行:"
  echo "sudo B_PUBLIC_KEY='B公钥' bash setup-ab-entry.sh"
  exit 0
fi

echo "==> 写入 WireGuard 配置"
cat > "/etc/wireguard/${WG_NAME}.conf" <<EOF
[Interface]
Address = ${ENTRY_TUN_IP}/30
ListenPort = ${WG_PORT}
PrivateKey = $(cat "/etc/wireguard/${WG_NAME}-entry.key")
Table = off
MTU = ${WG_MTU}

[Peer]
PublicKey = ${B_PUBLIC_KEY}
AllowedIPs = ${RELAY_TUN_IP}/32
EOF
chmod 600 "/etc/wireguard/${WG_NAME}.conf"

cat > "$CONFIG_FILE" <<EOF
WG_NAME=${WG_NAME}
WG_PORT=${WG_PORT}
WG_MTU=${WG_MTU}
WAN_IF=${WAN_IF}
ENTRY_PUBLIC_IP=${ENTRY_PUBLIC_IP}
ENTRY_TUN_IP=${ENTRY_TUN_IP}
RELAY_TUN_IP=${RELAY_TUN_IP}
PREFORWARD_RANGE=${PREFORWARD_RANGE}
EOF
chmod 600 "$CONFIG_FILE"

cat > "$APPLY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/ab-entry/config.env

delete_by_comment() {
  local table="$1" pattern="$2" rule
  while true; do
    rule="$(iptables -t "$table" -S 2>/dev/null | grep -F "$pattern" | head -n 1 || true)"
    [[ -n "$rule" ]] || break
    # shellcheck disable=SC2086
    iptables -t "$table" ${rule/-A/-D} 2>/dev/null || break
  done
}

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
cat > /etc/sysctl.d/99-ab-entry.conf <<SYSCTL
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
SYSCTL

if ! wg show "$WG_NAME" >/dev/null 2>&1; then
  wg-quick up "$WG_NAME"
fi

delete_by_comment nat AB-ENTRY
delete_by_comment filter AB-ENTRY
delete_by_comment mangle AB-ENTRY

iptables -C INPUT -p udp --dport "$WG_PORT" -m comment --comment "AB-ENTRY-WG ${WG_PORT}" -j ACCEPT 2>/dev/null || \
  iptables -I INPUT -p udp --dport "$WG_PORT" -m comment --comment "AB-ENTRY-WG ${WG_PORT}" -j ACCEPT

for proto in tcp udp; do
  comment="AB-ENTRY-RANGE ${proto}:${PREFORWARD_RANGE}->${RELAY_TUN_IP}"
  iptables -t nat -A PREROUTING -i "$WAN_IF" -p "$proto" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j DNAT --to-destination "$RELAY_TUN_IP"
  iptables -t nat -A POSTROUTING -o "$WG_NAME" -p "$proto" -d "$RELAY_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j SNAT --to-source "$ENTRY_TUN_IP"
  iptables -A FORWARD -i "$WAN_IF" -o "$WG_NAME" -p "$proto" -d "$RELAY_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT
done
iptables -A FORWARD -i "$WG_NAME" -o "$WAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "AB-ENTRY-RETURN" -j ACCEPT
iptables -t mangle -A FORWARD -o "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -m comment --comment "AB-ENTRY-MSS-OUT" -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -A FORWARD -i "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -m comment --comment "AB-ENTRY-MSS-IN" -j TCPMSS --clamp-mss-to-pmtu
EOF
chmod 755 "$APPLY_BIN"

cat > "$REMOVE_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/ab-entry/config.env

delete_by_comment() {
  local table="$1" pattern="$2" rule
  while true; do
    rule="$(iptables -t "$table" -S 2>/dev/null | grep -F "$pattern" | head -n 1 || true)"
    [[ -n "$rule" ]] || break
    # shellcheck disable=SC2086
    iptables -t "$table" ${rule/-A/-D} 2>/dev/null || break
  done
}

delete_by_comment nat AB-ENTRY
delete_by_comment filter AB-ENTRY
delete_by_comment mangle AB-ENTRY
wg-quick down "$WG_NAME" >/dev/null 2>&1 || true
EOF
chmod 755 "$REMOVE_BIN"

cat > "$CHECK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/ab-entry/config.env

repair=0
need_repair() {
  repair=1
  logger -t ab-entry-check "$*"
}

wg show "$WG_NAME" >/dev/null 2>&1 || need_repair "WireGuard ${WG_NAME} is not running"
iptables -C INPUT -p udp --dport "$WG_PORT" -m comment --comment "AB-ENTRY-WG ${WG_PORT}" -j ACCEPT 2>/dev/null || need_repair "missing WireGuard input rule"
for proto in tcp udp; do
  comment="AB-ENTRY-RANGE ${proto}:${PREFORWARD_RANGE}->${RELAY_TUN_IP}"
  iptables -t nat -C PREROUTING -i "$WAN_IF" -p "$proto" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j DNAT --to-destination "$RELAY_TUN_IP" 2>/dev/null || need_repair "missing ${proto} DNAT rule"
  iptables -t nat -C POSTROUTING -o "$WG_NAME" -p "$proto" -d "$RELAY_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j SNAT --to-source "$ENTRY_TUN_IP" 2>/dev/null || need_repair "missing ${proto} SNAT rule"
  iptables -C FORWARD -i "$WAN_IF" -o "$WG_NAME" -p "$proto" -d "$RELAY_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || need_repair "missing ${proto} FORWARD rule"
done

if (( repair )); then
  /usr/local/sbin/ab-entry-apply
fi
EOF
chmod 755 "$CHECK_BIN"

cat > "$HELPER_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/ab-entry/config.env
case "${1:-status}" in
  status)
    systemctl status ab-entry.service ab-entry-check.timer --no-pager --lines=8 || true
    wg show "$WG_NAME" 2>/dev/null || true
    iptables -t nat -S PREROUTING | grep -F AB-ENTRY || true
    ;;
  list) iptables -t nat -S PREROUTING | grep -F AB-ENTRY || true ;;
  repair|check) /usr/local/sbin/ab-entry-check ;;
  restart) /usr/local/bin/ab-entry-restart ;;
  on|start) systemctl enable --now ab-entry.service ab-entry-check.timer ;;
  off|stop) systemctl disable --now ab-entry-check.timer ab-entry.service ;;
  logs) journalctl -u ab-entry.service -u ab-entry-check.service --no-pager "${@:2}" ;;
  *) echo "usage: ab-entry status|list|repair|restart|on|off|logs" >&2; exit 2 ;;
esac
EOF
chmod 755 "$HELPER_BIN"

cat > "$RESTART_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl restart ab-entry.service
systemctl enable --now ab-entry-check.timer >/dev/null
systemctl start ab-entry-check.service >/dev/null 2>&1 || true
ab-entry status
EOF
chmod 755 "$RESTART_BIN"

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=AB entry port forward gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${APPLY_BIN}
ExecStop=${REMOVE_BIN}

[Install]
WantedBy=multi-user.target
EOF

cat > "$CHECK_UNIT_FILE" <<EOF
[Unit]
Description=AB entry self-healing check
After=network-online.target ab-entry.service
Wants=network-online.target ab-entry.service

[Service]
Type=oneshot
ExecStart=${CHECK_BIN}
EOF

cat > "$CHECK_TIMER_FILE" <<'EOF'
[Unit]
Description=Run AB entry self-healing check

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true
Unit=ab-entry-check.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable ab-entry.service >/dev/null
systemctl restart ab-entry.service
systemctl enable --now ab-entry-check.timer >/dev/null
systemctl start ab-entry-check.service >/dev/null 2>&1 || true

echo
echo "============================================================"
echo " A 入口机配置完成"
echo "------------------------------------------------------------"
echo " 用户访问:      ${ENTRY_PUBLIC_IP}:${PREFORWARD_RANGE/:/-}"
echo " WireGuard:     UDP ${WG_PORT}, ${ENTRY_TUN_IP}/30 -> ${RELAY_TUN_IP}/30"
echo " 端口预转发:    TCP/UDP ${PREFORWARD_RANGE} -> B ${RELAY_TUN_IP}:同端口"
echo " A 公钥:        ${ENTRY_PUBLIC_KEY}"
echo "------------------------------------------------------------"
echo " B 中继机需要填写:"
echo "   A_ENDPOINT=${ENTRY_PUBLIC_IP}"
echo "   A_PUBLIC_KEY='${ENTRY_PUBLIC_KEY}'"
echo "------------------------------------------------------------"
echo " 管理: sudo ab-entry status | repair | restart | off | on | logs -n 80"
echo "============================================================"
