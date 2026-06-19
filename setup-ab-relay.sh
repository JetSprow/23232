#!/usr/bin/env bash
# B 中继机脚本：接收 A 的 WireGuard 转发，再转发到 C 小鸡所在机器同端口。
# 拓扑: 用户 -> A -> wg-ab -> B -> C:20000-30000 -> 小鸡
set -euo pipefail
trap 'echo "[ERROR] 脚本在第 ${LINENO} 行退出: ${BASH_COMMAND}" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "需要 root 权限 (sudo)"; exit 1; }
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu"; exit 1; }

STATE_DIR="/etc/ab-relay"
CONFIG_FILE="$STATE_DIR/config.env"
APPLY_BIN="/usr/local/sbin/ab-relay-apply"
REMOVE_BIN="/usr/local/sbin/ab-relay-remove"
CHECK_BIN="/usr/local/sbin/ab-relay-check"
HELPER_BIN="/usr/local/bin/ab-relay"
RESTART_BIN="/usr/local/bin/ab-relay-restart"
UNIT_FILE="/etc/systemd/system/ab-relay.service"
CHECK_UNIT_FILE="/etc/systemd/system/ab-relay-check.service"
CHECK_TIMER_FILE="/etc/systemd/system/ab-relay-check.timer"

WG_NAME="${WG_NAME:-wg-ab}"
WG_PORT="${WG_PORT:-51821}"
WG_MTU="${WG_MTU:-1280}"
ENTRY_TUN_IP="${ENTRY_TUN_IP:-10.66.0.1}"
RELAY_TUN_IP="${RELAY_TUN_IP:-10.66.0.2}"
A_ENDPOINT="${A_ENDPOINT:-}"
A_PUBLIC_KEY="${A_PUBLIC_KEY:-}"
C_TARGET="${C_TARGET:-}"
C_TARGET_IP="${C_TARGET_IP:-}"
PREFORWARD_RANGE="${PREFORWARD_RANGE:-20000:30000}"
WAN_IF="${WAN_IF:-}"

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

valid_range() {
  local low="${1%:*}" high="${1#*:}"
  valid_port "$low" && valid_port "$high" && (( low <= high ))
}

resolve_ipv4() {
  local host="$1"
  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "$host"
    return 0
  fi
  getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}'
}

# 从 apt 报错日志里提取坏源的主机/路径关键字（任何 "does not have a Release file"
# 或 "Failed to fetch ... Release" 的第三方源），临时禁用对应 sources 文件后重试。
# 比只认 bullseye-backports 更通用：ookla/speedtest、各类 packagecloud/ppa 坏源都能自愈。
disable_broken_apt_repos() {
  local log_file="$1" tokens=() tok file matched=0
  while IFS= read -r tok; do
    [[ -n "$tok" ]] && tokens+=("$tok")
  done < <(grep -oiE "https?://[^ '\"]+" "$log_file" 2>/dev/null \
            | sed -E 's#https?://##; s#/$##' | sort -u)
  [[ ${#tokens[@]} -eq 0 ]] && return 1
  echo "==> 检测到不可用的 APT 源，自动禁用后重试:"
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    for tok in "${tokens[@]}"; do
      grep -qiF "$tok" "$file" || continue
      cp -n "$file" "${file}.bak" 2>/dev/null || true
      case "$file" in
        *.sources) mv "$file" "${file}.disabled"; echo "   disabled: ${file} (${tok})" ;;
        *) sed -i "\#${tok}#s/^[[:space:]]*\(deb\|deb-src\)[[:space:]]/# disabled by ab-relay setup: &/" "$file"; echo "   patched:  ${file} (${tok})" ;;
      esac
      matched=1
      break
    done
  done < <(find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) 2>/dev/null)
  [[ $matched -eq 1 ]] && return 0 || return 1
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
      *) sed -i '/bullseye-backports/s/^[[:space:]]*\(deb\|deb-src\)[[:space:]]/# disabled by ab-relay setup: &/' "$file"; echo "   patched:  ${file}" ;;
    esac
  done < <(find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) 2>/dev/null)
}

apt_update_with_repair() {
  local log_file="/tmp/ab-relay-apt-update.log"
  if apt-get update -qq >"$log_file" 2>&1; then
    rm -f "$log_file"
    return 0
  fi
  # 第一轮：泛化禁用所有报错的坏源后重试
  if disable_broken_apt_repos "$log_file"; then
    if apt-get update -qq >"$log_file" 2>&1; then
      rm -f "$log_file"
      return 0
    fi
  fi
  # 兜底：专门处理 bullseye-backports
  if grep -qi 'bullseye-backports' "$log_file"; then
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

valid_port "$WG_PORT" || { echo "WireGuard 端口无效: $WG_PORT"; exit 1; }
valid_range "$PREFORWARD_RANGE" || { echo "端口范围无效，应类似 20000:30000"; exit 1; }

echo "==> 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt_update_with_repair
apt-get install -y -qq wireguard iproute2 iptables curl ca-certificates

WAN_IF="${WAN_IF:-$(ip -4 route show default | awk '/default/ {print $5; exit}')}"
[[ -n "$WAN_IF" ]] || { echo "无法识别默认出口网卡"; exit 1; }

echo "==> 生成 WireGuard 密钥"
mkdir -p /etc/wireguard "$STATE_DIR"
chmod 700 /etc/wireguard "$STATE_DIR"
umask 077
[[ -f "/etc/wireguard/${WG_NAME}-relay.key" ]] || wg genkey | tee "/etc/wireguard/${WG_NAME}-relay.key" | wg pubkey > "/etc/wireguard/${WG_NAME}-relay.pub"
RELAY_PUBLIC_KEY="$(cat "/etc/wireguard/${WG_NAME}-relay.pub")"

echo
echo "============================================================"
echo " B 中继机 WireGuard 公钥，粘贴到 A 入口脚本:"
echo "   ${RELAY_PUBLIC_KEY}"
echo "============================================================"
echo

if [[ -z "$A_ENDPOINT" ]]; then
  read -rp "A 入口机公网 IPv4/域名；暂时没有可直接回车退出: " A_ENDPOINT
fi
if [[ -z "$A_PUBLIC_KEY" ]]; then
  read -rp "A 入口机 WireGuard 公钥；暂时没有可直接回车退出: " A_PUBLIC_KEY
fi
if [[ -z "$A_ENDPOINT" || -z "$A_PUBLIC_KEY" ]]; then
  echo "已生成 B 公钥。请先到 A 运行 setup-ab-entry.sh，并把 B 公钥粘贴进去。"
  echo "拿到 A 公网地址和 A 公钥后，再回来运行:"
  echo "sudo A_ENDPOINT=A公网IP A_PUBLIC_KEY='A公钥' C_TARGET=C公网IP bash setup-ab-relay.sh"
  exit 0
fi

if [[ -z "$C_TARGET" ]]; then
  read -rp "C 小鸡所在机器公网 IPv4/域名: " C_TARGET
fi
[[ -n "$C_TARGET" ]] || { echo "C_TARGET 不能为空"; exit 1; }

A_ENDPOINT_IP="$(resolve_ipv4 "$A_ENDPOINT" || true)"
C_TARGET_IP="${C_TARGET_IP:-$(resolve_ipv4 "$C_TARGET" || true)}"
[[ -n "$A_ENDPOINT_IP" ]] || { echo "无法解析 A_ENDPOINT IPv4: $A_ENDPOINT"; exit 1; }
[[ -n "$C_TARGET_IP" ]] || { echo "无法解析 C_TARGET IPv4: $C_TARGET"; exit 1; }

echo "==> 写入 WireGuard 配置"
cat > "/etc/wireguard/${WG_NAME}.conf" <<EOF
[Interface]
Address = ${RELAY_TUN_IP}/30
PrivateKey = $(cat "/etc/wireguard/${WG_NAME}-relay.key")
Table = off
MTU = ${WG_MTU}

[Peer]
PublicKey = ${A_PUBLIC_KEY}
Endpoint = ${A_ENDPOINT_IP}:${WG_PORT}
AllowedIPs = ${ENTRY_TUN_IP}/32
PersistentKeepalive = 25
EOF
chmod 600 "/etc/wireguard/${WG_NAME}.conf"

cat > "$CONFIG_FILE" <<EOF
WG_NAME=${WG_NAME}
WG_PORT=${WG_PORT}
WG_MTU=${WG_MTU}
WAN_IF=${WAN_IF}
ENTRY_TUN_IP=${ENTRY_TUN_IP}
RELAY_TUN_IP=${RELAY_TUN_IP}
A_ENDPOINT=${A_ENDPOINT}
A_ENDPOINT_IP=${A_ENDPOINT_IP}
C_TARGET=${C_TARGET}
C_TARGET_IP=${C_TARGET_IP}
PREFORWARD_RANGE=${PREFORWARD_RANGE}
EOF
chmod 600 "$CONFIG_FILE"

cat > "$APPLY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/ab-relay/config.env

resolve_ipv4() {
  local host="$1"
  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "$host"
    return 0
  fi
  getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}'
}

update_config_value() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" 'BEGIN{done=0} index($0,key"=")==1{print key"="value; done=1; next} {print} END{if(!done) print key"="value}' /etc/ab-relay/config.env > "$tmp"
  cat "$tmp" > /etc/ab-relay/config.env
  rm -f "$tmp"
}

delete_by_comment() {
  local table="$1" pattern="$2" rule
  while true; do
    rule="$(iptables -t "$table" -S 2>/dev/null | grep -F "$pattern" | head -n 1 || true)"
    [[ -n "$rule" ]] || break
    # shellcheck disable=SC2086
    iptables -t "$table" ${rule/-A/-D} 2>/dev/null || break
  done
}

new_a="$(resolve_ipv4 "$A_ENDPOINT" || true)"
if [[ -n "$new_a" && "$new_a" != "$A_ENDPOINT_IP" ]]; then
  logger -t ab-relay-apply "A endpoint changed: ${A_ENDPOINT_IP} -> ${new_a}"
  sed -i "s#^Endpoint = .*#Endpoint = ${new_a}:${WG_PORT}#" "/etc/wireguard/${WG_NAME}.conf"
  A_ENDPOINT_IP="$new_a"
  update_config_value A_ENDPOINT_IP "$A_ENDPOINT_IP"
fi
new_c="$(resolve_ipv4 "$C_TARGET" || true)"
if [[ -n "$new_c" && "$new_c" != "$C_TARGET_IP" ]]; then
  logger -t ab-relay-apply "C target changed: ${C_TARGET_IP} -> ${new_c}"
  C_TARGET_IP="$new_c"
  update_config_value C_TARGET_IP "$C_TARGET_IP"
fi

current_wan="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
if [[ -n "$current_wan" && "$current_wan" != "$WAN_IF" ]]; then
  WAN_IF="$current_wan"
  update_config_value WAN_IF "$WAN_IF"
fi

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
cat > /etc/sysctl.d/99-ab-relay.conf <<SYSCTL
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
SYSCTL

if ! wg show "$WG_NAME" >/dev/null 2>&1; then
  wg-quick up "$WG_NAME"
fi
wg set "$WG_NAME" peer "$(awk '/^PublicKey = /{print $3; exit}' "/etc/wireguard/${WG_NAME}.conf")" endpoint "${A_ENDPOINT_IP}:${WG_PORT}" persistent-keepalive 25 >/dev/null 2>&1 || true

delete_by_comment nat AB-RELAY
delete_by_comment filter AB-RELAY
delete_by_comment mangle AB-RELAY

for proto in tcp udp; do
  comment="AB-RELAY-RANGE ${proto}:${PREFORWARD_RANGE}->${C_TARGET_IP}"
  iptables -t nat -A PREROUTING -i "$WG_NAME" -p "$proto" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j DNAT --to-destination "$C_TARGET_IP"
  iptables -t nat -A POSTROUTING -o "$WAN_IF" -p "$proto" -d "$C_TARGET_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j MASQUERADE
  iptables -A FORWARD -i "$WG_NAME" -o "$WAN_IF" -p "$proto" -d "$C_TARGET_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT
done
iptables -A FORWARD -i "$WAN_IF" -o "$WG_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "AB-RELAY-RETURN" -j ACCEPT
iptables -t mangle -A FORWARD -o "$WAN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment "AB-RELAY-MSS-OUT" -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -A FORWARD -i "$WAN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment "AB-RELAY-MSS-IN" -j TCPMSS --clamp-mss-to-pmtu
EOF
chmod 755 "$APPLY_BIN"

cat > "$REMOVE_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/ab-relay/config.env

delete_by_comment() {
  local table="$1" pattern="$2" rule
  while true; do
    rule="$(iptables -t "$table" -S 2>/dev/null | grep -F "$pattern" | head -n 1 || true)"
    [[ -n "$rule" ]] || break
    # shellcheck disable=SC2086
    iptables -t "$table" ${rule/-A/-D} 2>/dev/null || break
  done
}

delete_by_comment nat AB-RELAY
delete_by_comment filter AB-RELAY
delete_by_comment mangle AB-RELAY
wg-quick down "$WG_NAME" >/dev/null 2>&1 || true
EOF
chmod 755 "$REMOVE_BIN"

cat > "$CHECK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/ab-relay/config.env

repair=0
need_repair() {
  repair=1
  logger -t ab-relay-check "$*"
}

resolve_ipv4() {
  local host="$1"
  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "$host"
    return 0
  fi
  getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}'
}

resolved_a="$(resolve_ipv4 "$A_ENDPOINT" || true)"
if [[ -n "$resolved_a" && "$resolved_a" != "$A_ENDPOINT_IP" ]]; then
  need_repair "A endpoint changed: ${A_ENDPOINT_IP} -> ${resolved_a}"
fi
resolved_c="$(resolve_ipv4 "$C_TARGET" || true)"
if [[ -n "$resolved_c" && "$resolved_c" != "$C_TARGET_IP" ]]; then
  need_repair "C target changed: ${C_TARGET_IP} -> ${resolved_c}"
fi

wg show "$WG_NAME" >/dev/null 2>&1 || need_repair "WireGuard ${WG_NAME} is not running"
for proto in tcp udp; do
  comment="AB-RELAY-RANGE ${proto}:${PREFORWARD_RANGE}->${C_TARGET_IP}"
  iptables -t nat -C PREROUTING -i "$WG_NAME" -p "$proto" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j DNAT --to-destination "$C_TARGET_IP" 2>/dev/null || need_repair "missing ${proto} DNAT rule"
  iptables -t nat -C POSTROUTING -o "$WAN_IF" -p "$proto" -d "$C_TARGET_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j MASQUERADE 2>/dev/null || need_repair "missing ${proto} MASQUERADE rule"
  iptables -C FORWARD -i "$WG_NAME" -o "$WAN_IF" -p "$proto" -d "$C_TARGET_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || need_repair "missing ${proto} FORWARD rule"
done

if (( repair )); then
  /usr/local/sbin/ab-relay-apply
fi
EOF
chmod 755 "$CHECK_BIN"

cat > "$HELPER_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/ab-relay/config.env
case "${1:-status}" in
  status)
    systemctl status ab-relay.service ab-relay-check.timer --no-pager --lines=8 || true
    wg show "$WG_NAME" 2>/dev/null || true
    iptables -t nat -S PREROUTING | grep -F AB-RELAY || true
    ;;
  list) iptables -t nat -S PREROUTING | grep -F AB-RELAY || true ;;
  repair|check) /usr/local/sbin/ab-relay-check ;;
  restart) /usr/local/bin/ab-relay-restart ;;
  on|start) systemctl enable --now ab-relay.service ab-relay-check.timer ;;
  off|stop) systemctl disable --now ab-relay-check.timer ab-relay.service ;;
  logs) journalctl -u ab-relay.service -u ab-relay-check.service --no-pager "${@:2}" ;;
  *) echo "usage: ab-relay status|list|repair|restart|on|off|logs" >&2; exit 2 ;;
esac
EOF
chmod 755 "$HELPER_BIN"

cat > "$RESTART_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl restart ab-relay.service
systemctl enable --now ab-relay-check.timer >/dev/null
systemctl start ab-relay-check.service >/dev/null 2>&1 || true
ab-relay status
EOF
chmod 755 "$RESTART_BIN"

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=AB relay to C node
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
Description=AB relay self-healing check
After=network-online.target ab-relay.service
Wants=network-online.target ab-relay.service

[Service]
Type=oneshot
ExecStart=${CHECK_BIN}
EOF

cat > "$CHECK_TIMER_FILE" <<'EOF'
[Unit]
Description=Run AB relay self-healing check

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true
Unit=ab-relay-check.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable ab-relay.service >/dev/null
systemctl restart ab-relay.service
systemctl enable --now ab-relay-check.timer >/dev/null
systemctl start ab-relay-check.service >/dev/null 2>&1 || true

echo
echo "============================================================"
echo " B 中继机配置完成"
echo "------------------------------------------------------------"
echo " WireGuard:     ${RELAY_TUN_IP}/30 -> ${ENTRY_TUN_IP}/30"
echo " A Endpoint:    ${A_ENDPOINT_IP}:${WG_PORT}"
echo " C 目标机器:    ${C_TARGET_IP}"
echo " 端口预转发:    TCP/UDP ${PREFORWARD_RANGE} -> C 同端口"
echo " B 公钥:        ${RELAY_PUBLIC_KEY}"
echo "------------------------------------------------------------"
echo " A 入口机需要填写:"
echo "   B_PUBLIC_KEY='${RELAY_PUBLIC_KEY}'"
echo "------------------------------------------------------------"
echo " 管理: sudo ab-relay status | repair | restart | off | on | logs -n 80"
echo "============================================================"
