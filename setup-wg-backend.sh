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
CHECK_BIN="/usr/local/sbin/wg-backend-check"
HELPER_BIN="/usr/local/bin/wg-be"
RESTART_BIN="/usr/local/bin/wg-opt-restart"
UNIT_FILE="/etc/systemd/system/wg-backend.service"
CHECK_UNIT_FILE="/etc/systemd/system/wg-backend-check.service"
CHECK_TIMER_FILE="/etc/systemd/system/wg-backend-check.timer"

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

# 从 apt 报错日志里提取坏源的主机/路径关键字（任何 "does not have a Release file"
# 或 "Failed to fetch ... Release" 的第三方源），临时禁用对应 sources 文件后重试。
# 比只认 bullseye-backports 更通用：ookla/speedtest、各类 packagecloud/ppa 坏源都能自愈。
disable_broken_apt_repos() {
  local log_file="$1" tokens=() tok file matched=0
  # 提取形如 https://host/path 的源 URL（来自 "The repository 'URL suite Release'..."）
  while IFS= read -r tok; do
    [[ -n "$tok" ]] && tokens+=("$tok")
  done < <(grep -oiE "https?://[^ '\"]+" "$log_file" 2>/dev/null \
            | sed -E 's#https?://##; s#/$##' | sort -u)
  [[ ${#tokens[@]} -eq 0 ]] && return 1
  echo "==> 检测到不可用的 APT 源，自动禁用后重试:"
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    for tok in "${tokens[@]}"; do
      # 用主机+首段路径做匹配，避免误伤同主机的其它正常源
      grep -qiF "$tok" "$file" || continue
      cp -n "$file" "${file}.bak" 2>/dev/null || true
      case "$file" in
        *.sources) mv "$file" "${file}.disabled"; echo "   disabled: ${file} (${tok})" ;;
        *) sed -i "\#${tok}#s/^[[:space:]]*\(deb\|deb-src\)[[:space:]]/# disabled by wg setup: &/" "$file"; echo "   patched:  ${file} (${tok})" ;;
      esac
      matched=1
      break
    done
  done < <(find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) 2>/dev/null)
  [[ $matched -eq 1 ]] && return 0 || return 1
}

apt_update_with_repair() {
  local log_file="/tmp/wg-backend-apt-update.log"
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
  # 兜底：专门处理 bullseye-backports（移除 Release file 检测条件，直接清理）
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
while ip rule del from "$GUEST_SUBNET" table 2010 pref 2010 2>/dev/null; do :; done
while ip rule del from 10.255.0.2 table 2010 pref 2011 2>/dev/null; do :; done
ip route flush table 2010 2>/dev/null || true
ip tunnel del gre-opt 2>/dev/null || true
while iptables -D FORWARD -i "$INCUS_BRIDGE" -o gre-opt -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -i gre-opt -o "$INCUS_BRIDGE" -j ACCEPT 2>/dev/null; do :; done
while iptables -t nat -D POSTROUTING -s "$GUEST_SUBNET" -o gre-opt -j RETURN 2>/dev/null; do :; done

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
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w "net.ipv4.conf.${INCUS_BRIDGE}.rp_filter=0" >/dev/null 2>&1 || true
sysctl -w "net.ipv4.conf.${WG_NAME}.rp_filter=0" >/dev/null 2>&1 || true
cat > /etc/sysctl.d/99-wg-backend.conf <<SYSCTL
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
SYSCTL

if ! wg show "$WG_NAME" >/dev/null 2>&1; then
  wg-quick up "$WG_NAME"
fi

ip route replace "$GUEST_SUBNET" dev "$INCUS_BRIDGE" table "$WG_TABLE"
ip route replace default dev "$WG_NAME" table "$WG_TABLE"
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
iptables -t nat -C POSTROUTING -s "$GUEST_SUBNET" -o "$WG_NAME" -j SNAT --to-source "$BACKEND_TUN_IP" 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s "$GUEST_SUBNET" -o "$WG_NAME" -j SNAT --to-source "$BACKEND_TUN_IP"

if [[ "${PREFORWARD_ENABLE:-1}" == "1" ]]; then
  for proto in tcp udp; do
    comment="WG-BE-RANGE ${proto}:${PREFORWARD_RANGE}"
    local_comment="WG-BE-LOCAL ${proto}:${PREFORWARD_RANGE}"
    iptables -t nat -C PREROUTING -i "$WG_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$local_comment" -j REDIRECT 2>/dev/null || \
      iptables -t nat -A PREROUTING -i "$WG_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$local_comment" -j REDIRECT
    iptables -C INPUT -i "$WG_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -i "$WG_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT
  done
fi
EOF
chmod +x "$APPLY_BIN"

cat > "$CHECK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/wg-backend/config.env

repair_needed=0

need_repair() {
  repair_needed=1
  logger -t wg-backend-check "$*"
}

if ! wg show "$WG_NAME" >/dev/null 2>&1; then
  need_repair "WireGuard interface ${WG_NAME} is missing"
else
  ip route show table "$WG_TABLE" | grep -Eq "^default dev ${WG_NAME}( |$)" || need_repair "missing policy default route in table ${WG_TABLE}"
  ip route show table "$WG_TABLE" | grep -F "$GUEST_SUBNET" | grep -F "dev $INCUS_BRIDGE" >/dev/null || need_repair "missing guest subnet route in table ${WG_TABLE}"
  ip rule show | grep -F "from $GUEST_SUBNET lookup $WG_TABLE" >/dev/null || need_repair "missing guest subnet ip rule"
  ip rule show | grep -F "from $BACKEND_TUN_IP lookup $WG_TABLE" >/dev/null || need_repair "missing backend tunnel ip rule"

  iptables -t mangle -C FORWARD -o "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || need_repair "missing outbound TCPMSS rule"
  iptables -t mangle -C FORWARD -i "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || need_repair "missing inbound TCPMSS rule"
  iptables -C FORWARD -i "$INCUS_BRIDGE" -o "$WG_NAME" -j ACCEPT 2>/dev/null || need_repair "missing guest to WireGuard forward rule"
  iptables -C FORWARD -i "$WG_NAME" -o "$INCUS_BRIDGE" -j ACCEPT 2>/dev/null || need_repair "missing WireGuard to guest forward rule"
  iptables -t nat -C POSTROUTING -s "$GUEST_SUBNET" -o "$WG_NAME" -j SNAT --to-source "$BACKEND_TUN_IP" 2>/dev/null || need_repair "missing backend SNAT rule"

  if [[ "${PREFORWARD_ENABLE:-1}" == "1" ]]; then
    for proto in tcp udp; do
      comment="WG-BE-RANGE ${proto}:${PREFORWARD_RANGE}"
      local_comment="WG-BE-LOCAL ${proto}:${PREFORWARD_RANGE}"
      iptables -t nat -C PREROUTING -i "$WG_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$local_comment" -j REDIRECT 2>/dev/null || need_repair "missing local ${proto} preforward rule"
      iptables -C INPUT -i "$WG_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || need_repair "missing ${proto} preforward input rule"
    done
  fi
fi

if ((repair_needed)); then
  /usr/local/sbin/wg-backend-apply
fi
EOF
chmod +x "$CHECK_BIN"

cat > "$REMOVE_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/wg-backend/config.env

while iptables -t mangle -D FORWARD -o "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
while iptables -t mangle -D FORWARD -i "$WG_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
while iptables -t nat -D POSTROUTING -s "$GUEST_SUBNET" -o "$WG_NAME" -j SNAT --to-source "$BACKEND_TUN_IP" 2>/dev/null; do :; done
while iptables -t nat -D POSTROUTING -s "$GUEST_SUBNET" -o "$WG_NAME" -j RETURN 2>/dev/null; do :; done
for proto in tcp udp; do
  comment="WG-BE-RANGE ${proto}:${PREFORWARD_RANGE}"
  local_comment="WG-BE-LOCAL ${proto}:${PREFORWARD_RANGE}"
  while iptables -t nat -D PREROUTING -i "$WG_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$local_comment" -j REDIRECT 2>/dev/null; do :; done
  while iptables -D INPUT -i "$WG_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; do :; done
done
while iptables -D FORWARD -i "$WG_NAME" -o "$INCUS_BRIDGE" -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -i "$INCUS_BRIDGE" -o "$WG_NAME" -j ACCEPT 2>/dev/null; do :; done
ip rule del from "$BACKEND_TUN_IP" table "$WG_TABLE" pref "$((WG_RULE_PREF + 1))" 2>/dev/null || true
ip rule del from "$GUEST_SUBNET" table "$WG_TABLE" pref "$WG_RULE_PREF" 2>/dev/null || true
ip route flush table "$WG_TABLE" 2>/dev/null || true
ip route flush cache 2>/dev/null || true
wg-quick down "$WG_NAME" >/dev/null 2>&1 || true
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
  sudo wg-be repair
  sudo wg-be status
USAGE
}

case "${1:-}" in
  on|enable|start) systemctl enable --now wg-backend.service wg-backend-check.timer ;;
  off|disable|stop) systemctl disable --now wg-backend-check.timer wg-backend.service ;;
  restart) /usr/local/bin/wg-opt-restart ;;
  repair|check) /usr/local/sbin/wg-backend-check ;;
  status)
    systemctl is-active wg-backend.service 2>/dev/null || true
    systemctl is-active wg-backend-check.timer 2>/dev/null || true
    wg show "$WG_NAME" 2>/dev/null || true
    ip rule show | grep -F "lookup ${WG_TABLE}" || true
    ip route show table "$WG_TABLE" 2>/dev/null || true
    ;;
  *) usage; exit 1 ;;
esac
EOF
chmod +x "$HELPER_BIN"

cat > "$RESTART_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl restart wg-backend.service
systemctl enable --now wg-backend-check.timer >/dev/null
systemctl start wg-backend-check.service >/dev/null 2>&1 || true
wg-be status
EOF
chmod +x "$RESTART_BIN"

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=WireGuard backend for optimized gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${APPLY_BIN}
ExecStop=${REMOVE_BIN}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > "$CHECK_UNIT_FILE" <<EOF
[Unit]
Description=WireGuard optimized backend self-healing check
After=network-online.target wg-backend.service
Wants=network-online.target wg-backend.service

[Service]
Type=oneshot
ExecStart=${CHECK_BIN}
EOF

cat > "$CHECK_TIMER_FILE" <<EOF
[Unit]
Description=Run WireGuard optimized backend self-healing check

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true
Unit=wg-backend-check.service

[Install]
WantedBy=timers.target
EOF

echo "==> 启动 WireGuard 后端"
systemctl daemon-reload
systemctl enable wg-backend.service >/dev/null
systemctl restart wg-backend.service
systemctl enable --now wg-backend-check.timer >/dev/null
systemctl start wg-backend-check.service >/dev/null 2>&1 || true

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
echo "   sudo wg-be repair"
echo "   sudo wg-be restart"
echo "   sudo wg-be off"
echo "   sudo wg-be on"
echo "   sudo wg-opt-restart"
echo " 测试:"
echo "   ping -c 3 ${GATEWAY_TUN_IP}"
echo "============================================================"
