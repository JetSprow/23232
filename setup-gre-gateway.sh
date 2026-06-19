#!/usr/bin/env bash
# 优化线路 GRE 网关脚本
# 运行位置: 优化线路机器
# 作用: 建立 GRE 到普通 Incus 节点，负责小鸡出口 SNAT 和公网端口 DNAT。
# 用法:
#   sudo bash setup-gre-gateway.sh
#   sudo BACKEND_PUBLIC_IP=1.2.3.4 GUEST_SUBNET=10.10.0.0/22 bash setup-gre-gateway.sh
set -euo pipefail
trap 'echo "[ERROR] 脚本在第 ${LINENO} 行退出: ${BASH_COMMAND}" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "需要 root 权限 (sudo)"; exit 1; }
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu"; exit 1; }

STATE_DIR="/etc/gre-gateway"
CONFIG_FILE="$STATE_DIR/config.env"
APPLY_BIN="/usr/local/sbin/gre-gateway-apply"
REMOVE_BIN="/usr/local/sbin/gre-gateway-remove"
CHECK_BIN="/usr/local/sbin/gre-gateway-check"
HELPER_BIN="/usr/local/bin/gre-gw"
RESTART_BIN="/usr/local/bin/gre-gateway-restart"
UNIT_FILE="/etc/systemd/system/gre-gateway.service"
CHECK_UNIT_FILE="/etc/systemd/system/gre-gateway-check.service"
CHECK_TIMER_FILE="/etc/systemd/system/gre-gateway-check.timer"

GRE_NAME="${GRE_NAME:-gre-incus}"
GRE_TABLE="${GRE_TABLE:-}"
GATEWAY_TUN_IP="${GATEWAY_TUN_IP:-10.255.0.1}"
BACKEND_TUN_IP="${BACKEND_TUN_IP:-10.255.0.2}"
GRE_MTU="${GRE_MTU:-1280}"
TCP_MSS="${TCP_MSS:-1240}"
GUEST_SUBNET="${GUEST_SUBNET:-}"
BACKEND_PUBLIC_IP="${BACKEND_PUBLIC_IP:-}"
GATEWAY_PUBLIC_IP="${GATEWAY_PUBLIC_IP:-}"
WAN_IF="${WAN_IF:-}"
PREFORWARD_ENABLE="${PREFORWARD_ENABLE:-1}"
PREFORWARD_RANGE="${PREFORWARD_RANGE:-20000:30000}"

valid_ip_or_host() {
  [[ -n "$1" && "$1" != *:* ]]
}

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
    if ! grep -qi 'bullseye-backports' "$file"; then
      continue
    fi
    cp -n "$file" "${file}.bak" 2>/dev/null || true
    case "$file" in
      *.sources)
        mv "$file" "${file}.disabled"
        echo "   disabled: ${file}"
        ;;
      *)
        sed -i '/bullseye-backports/s/^[[:space:]]*\(deb\|deb-src\)[[:space:]]/# disabled by gre setup: &/' "$file"
        echo "   patched:  ${file}"
        ;;
    esac
  done < <(find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) 2>/dev/null)
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
        *) sed -i "\#${tok}#s/^[[:space:]]*\(deb\|deb-src\)[[:space:]]/# disabled by gre setup: &/" "$file"; echo "   patched:  ${file} (${tok})" ;;
      esac
      matched=1
      break
    done
  done < <(find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) 2>/dev/null)
  [[ $matched -eq 1 ]] && return 0 || return 1
}

apt_update_with_repair() {
  local log_file="/tmp/gre-gateway-apt-update.log"
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
    if ! apt-get update -qq; then
      echo "仍然存在异常 APT 源，请检查以下文件:" >&2
      grep -Ril 'bullseye-backports' /etc/apt 2>/dev/null >&2 || true
      return 1
    fi
    rm -f "$log_file"
    return 0
  fi
  cat "$log_file" >&2
  rm -f "$log_file"
  return 1
}

if [[ -z "$BACKEND_PUBLIC_IP" ]]; then
  echo "普通 Incus 节点地址说明: 填小鸡所在普通线路机器的公网 IPv4 或 A 记录域名，不是小鸡内网 IP。"
  read -rp "普通 Incus 节点公网 IPv4/域名: " BACKEND_PUBLIC_IP
fi
valid_ip_or_host "$BACKEND_PUBLIC_IP" || { echo "普通节点地址无效，只支持 IPv4 或 A 记录域名"; exit 1; }

if [[ -z "$GUEST_SUBNET" ]]; then
  echo "小鸡网段说明: 填普通 Incus 节点 incusbr0 正在使用的 IPv4 网段，不是新建网段。"
  echo "查看命令: ip -4 addr show incusbr0"
  read -rp "小鸡/Incus bridge 网段 [10.10.0.0/22]: " GUEST_SUBNET
  GUEST_SUBNET="${GUEST_SUBNET:-10.10.0.0/22}"
fi
normalize_guest_subnet

echo "==> 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt_update_with_repair
apt-get install -y -qq iproute2 iptables curl ca-certificates

WAN_IF="${WAN_IF:-$(ip -4 route show default | awk '/default/ {print $5; exit}')}"
[[ -n "$WAN_IF" ]] || { echo "无法识别默认出口网卡"; exit 1; }

if [[ -z "$GATEWAY_PUBLIC_IP" ]]; then
  GATEWAY_PUBLIC_IP="$(ip -4 -o addr show dev "$WAN_IF" scope global | awk '{split($4,a,"/"); print a[1]; exit}')"
fi
[[ -n "$GATEWAY_PUBLIC_IP" ]] || { echo "无法识别优化节点本机 IPv4"; exit 1; }

BACKEND_RESOLVED_IP="$BACKEND_PUBLIC_IP"
if [[ ! "$BACKEND_PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  BACKEND_RESOLVED_IP="$(getent ahostsv4 "$BACKEND_PUBLIC_IP" | awk '{print $1; exit}')"
fi
[[ -n "$BACKEND_RESOLVED_IP" ]] || { echo "无法解析普通节点 IPv4: $BACKEND_PUBLIC_IP"; exit 1; }

echo "==> 写入配置"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
cat > "$CONFIG_FILE" <<EOF
GRE_NAME=${GRE_NAME}
WAN_IF=${WAN_IF}
GATEWAY_PUBLIC_IP=${GATEWAY_PUBLIC_IP}
BACKEND_ENDPOINT_HOST=${BACKEND_PUBLIC_IP}
BACKEND_PUBLIC_IP=${BACKEND_RESOLVED_IP}
GATEWAY_TUN_IP=${GATEWAY_TUN_IP}
BACKEND_TUN_IP=${BACKEND_TUN_IP}
GRE_MTU=${GRE_MTU}
TCP_MSS=${TCP_MSS}
GUEST_SUBNET=${GUEST_SUBNET}
PREFORWARD_ENABLE=${PREFORWARD_ENABLE}
PREFORWARD_RANGE=${PREFORWARD_RANGE}
EOF
chmod 600 "$CONFIG_FILE"

cat > "$APPLY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gre-gateway/config.env

resolve_ipv4() {
  local host="$1"
  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "$host"
    return 0
  fi
  getent ahostsv4 "$host" | awk '{print $1; exit}'
}

set_config() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" 'BEGIN{done=0} index($0,key"=")==1{print key"="value; done=1; next} {print} END{if(!done) print key"="value}' /etc/gre-gateway/config.env > "$tmp"
  cat "$tmp" > /etc/gre-gateway/config.env
  rm -f "$tmp"
}

current_wan="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
[[ -n "$current_wan" ]] && WAN_IF="$current_wan"
current_public="$(ip -4 -o addr show dev "$WAN_IF" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
[[ -n "$current_public" ]] && GATEWAY_PUBLIC_IP="$current_public"
resolved_backend="$(resolve_ipv4 "${BACKEND_ENDPOINT_HOST:-$BACKEND_PUBLIC_IP}" || true)"
[[ -n "$resolved_backend" ]] && BACKEND_PUBLIC_IP="$resolved_backend"
set_config WAN_IF "$WAN_IF"
set_config GATEWAY_PUBLIC_IP "$GATEWAY_PUBLIC_IP"
set_config BACKEND_PUBLIC_IP "$BACKEND_PUBLIC_IP"

sysctl -w net.ipv4.ip_forward=1 >/dev/null
cat > /etc/sysctl.d/99-gre-gateway.conf <<SYSCTL
net.ipv4.ip_forward=1
SYSCTL

ip tunnel del "$GRE_NAME" 2>/dev/null || true
ip tunnel add "$GRE_NAME" mode gre local "$GATEWAY_PUBLIC_IP" remote "$BACKEND_PUBLIC_IP" ttl 255
ip addr add "${GATEWAY_TUN_IP}/30" dev "$GRE_NAME"
ip link set "$GRE_NAME" mtu "$GRE_MTU" up
ip route replace "$GUEST_SUBNET" via "$BACKEND_TUN_IP" dev "$GRE_NAME"

while iptables -t mangle -S FORWARD 2>/dev/null | grep -F -- "-o $GRE_NAME " | grep -F -- "-j TCPMSS" >/tmp/gre-gw-mss-rule 2>/dev/null; do
  rule="$(cat /tmp/gre-gw-mss-rule)"
  iptables -t mangle ${rule/-A/-D} 2>/dev/null || break
done
while iptables -t mangle -S FORWARD 2>/dev/null | grep -F -- "-i $GRE_NAME " | grep -F -- "-j TCPMSS" >/tmp/gre-gw-mss-rule 2>/dev/null; do
  rule="$(cat /tmp/gre-gw-mss-rule)"
  iptables -t mangle ${rule/-A/-D} 2>/dev/null || break
done
rm -f /tmp/gre-gw-mss-rule

iptables -C INPUT -p 47 -s "$BACKEND_PUBLIC_IP" -j ACCEPT 2>/dev/null || iptables -I INPUT -p 47 -s "$BACKEND_PUBLIC_IP" -j ACCEPT
iptables -C FORWARD -i "$GRE_NAME" -o "$WAN_IF" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$GRE_NAME" -o "$WAN_IF" -j ACCEPT
iptables -C FORWARD -i "$WAN_IF" -o "$GRE_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$WAN_IF" -o "$GRE_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -C POSTROUTING -s "$GUEST_SUBNET" -o "$WAN_IF" -j SNAT --to-source "$GATEWAY_PUBLIC_IP" 2>/dev/null || iptables -t nat -A POSTROUTING -s "$GUEST_SUBNET" -o "$WAN_IF" -j SNAT --to-source "$GATEWAY_PUBLIC_IP"
iptables -t mangle -C FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -C FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

if [[ "${PREFORWARD_ENABLE:-1}" == "1" ]]; then
  for proto in tcp udp; do
    comment="GRE-GW-RANGE ${proto}:${PREFORWARD_RANGE}->${BACKEND_TUN_IP}"
    iptables -t nat -C PREROUTING -i "$WAN_IF" -p "$proto" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j DNAT --to-destination "$BACKEND_TUN_IP" 2>/dev/null || \
      iptables -t nat -A PREROUTING -i "$WAN_IF" -p "$proto" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j DNAT --to-destination "$BACKEND_TUN_IP"
    iptables -C FORWARD -i "$WAN_IF" -o "$GRE_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || \
      iptables -A FORWARD -i "$WAN_IF" -o "$GRE_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT
  done
fi
EOF
chmod +x "$APPLY_BIN"

cat > "$CHECK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gre-gateway/config.env

repair=0

need_repair() {
  repair=1
  logger -t gre-gateway-check "$*"
}

resolve_ipv4() {
  local host="$1"
  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "$host"
    return 0
  fi
  getent ahostsv4 "$host" | awk '{print $1; exit}'
}

current_wan="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
current_public=""
[[ -n "$current_wan" ]] && current_public="$(ip -4 -o addr show dev "$current_wan" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
resolved_backend="$(resolve_ipv4 "${BACKEND_ENDPOINT_HOST:-$BACKEND_PUBLIC_IP}" || true)"

[[ -n "$current_wan" && "$current_wan" != "${WAN_IF:-}" ]] && need_repair "WAN interface changed: ${WAN_IF:-unknown} -> ${current_wan}"
[[ -n "$current_public" && "$current_public" != "${GATEWAY_PUBLIC_IP:-}" ]] && need_repair "gateway public IPv4 changed: ${GATEWAY_PUBLIC_IP:-unknown} -> ${current_public}"
[[ -n "$resolved_backend" && "$resolved_backend" != "${BACKEND_PUBLIC_IP:-}" ]] && need_repair "backend endpoint changed: ${BACKEND_PUBLIC_IP:-unknown} -> ${resolved_backend}"

ip link show "$GRE_NAME" >/dev/null 2>&1 || need_repair "GRE interface missing"
ip route show "$GUEST_SUBNET" | grep -F "via $BACKEND_TUN_IP" | grep -F "dev $GRE_NAME" >/dev/null || need_repair "missing guest subnet route"
iptables -C INPUT -p 47 -s "${resolved_backend:-$BACKEND_PUBLIC_IP}" -j ACCEPT 2>/dev/null || need_repair "missing GRE input rule"
iptables -C FORWARD -i "$GRE_NAME" -o "$WAN_IF" -j ACCEPT 2>/dev/null || need_repair "missing GRE to WAN forward rule"
iptables -C FORWARD -i "$WAN_IF" -o "$GRE_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || need_repair "missing WAN return forward rule"
iptables -t nat -C POSTROUTING -s "$GUEST_SUBNET" -o "$WAN_IF" -j SNAT --to-source "${current_public:-$GATEWAY_PUBLIC_IP}" 2>/dev/null || need_repair "missing guest SNAT rule"
iptables -t mangle -C FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || need_repair "missing outbound TCPMSS rule"
iptables -t mangle -C FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || need_repair "missing inbound TCPMSS rule"

if [[ "${PREFORWARD_ENABLE:-1}" == "1" ]]; then
  for proto in tcp udp; do
    comment="GRE-GW-RANGE ${proto}:${PREFORWARD_RANGE}->${BACKEND_TUN_IP}"
    iptables -t nat -C PREROUTING -i "$WAN_IF" -p "$proto" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j DNAT --to-destination "$BACKEND_TUN_IP" 2>/dev/null || need_repair "missing ${proto} range DNAT rule"
    iptables -C FORWARD -i "$WAN_IF" -o "$GRE_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || need_repair "missing ${proto} range FORWARD rule"
  done
fi

if (( repair )); then
  /usr/local/sbin/gre-gateway-apply
fi
EOF
chmod +x "$CHECK_BIN"

cat > "$REMOVE_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gre-gateway/config.env

while iptables -t mangle -D FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TCP_MSS" 2>/dev/null; do :; done
while iptables -t mangle -D FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TCP_MSS" 2>/dev/null; do :; done
while iptables -t mangle -D FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
while iptables -t mangle -D FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
for proto in tcp udp; do
  comment="GRE-GW-RANGE ${proto}:${PREFORWARD_RANGE}->${BACKEND_TUN_IP}"
  while iptables -t nat -D PREROUTING -i "$WAN_IF" -p "$proto" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j DNAT --to-destination "$BACKEND_TUN_IP" 2>/dev/null; do :; done
  while iptables -D FORWARD -i "$WAN_IF" -o "$GRE_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; do :; done
done
while iptables -t nat -D POSTROUTING -s "$GUEST_SUBNET" -o "$WAN_IF" -j SNAT --to-source "$GATEWAY_PUBLIC_IP" 2>/dev/null; do :; done
while iptables -D FORWARD -i "$WAN_IF" -o "$GRE_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -i "$GRE_NAME" -o "$WAN_IF" -j ACCEPT 2>/dev/null; do :; done
while iptables -D INPUT -p 47 -s "$BACKEND_PUBLIC_IP" -j ACCEPT 2>/dev/null; do :; done

ip route del "$GUEST_SUBNET" via "$BACKEND_TUN_IP" dev "$GRE_NAME" 2>/dev/null || true
ip tunnel del "$GRE_NAME" 2>/dev/null || true
EOF
chmod +x "$REMOVE_BIN"

cat > "$HELPER_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gre-gateway/config.env

usage() {
  cat <<USAGE
用法:
  sudo gre-gw on
  sudo gre-gw off
  sudo gre-gw restart
  sudo gre-gw repair
  sudo gre-gw status
  sudo gre-gw logs
  sudo gre-gw add tcp|udp 外部端口 小鸡IP 内部端口
  sudo gre-gw del tcp|udp 外部端口 小鸡IP 内部端口
  sudo gre-gw list

说明:
  on/off/restart 只控制 GRE 隧道、核心路由和核心防火墙规则。
  默认会把 ${PREFORWARD_RANGE} 整段 TCP/UDP 预转发到普通节点 GRE IP，端口号保持不变。
  add/del 管理公网端口到小鸡内网 IP 的转发规则。
USAGE
}

status() {
  systemctl is-active gre-gateway.service 2>/dev/null || true
  ip -brief addr show "$GRE_NAME" 2>/dev/null || true
  ip route show "$GUEST_SUBNET" 2>/dev/null || true
  echo "pre-forward: ${PREFORWARD_ENABLE:-1} ${PREFORWARD_RANGE:-}"
  iptables -t nat -S | grep -E "GRE-GW|GRE-GW-RANGE|${GUEST_SUBNET}|${GRE_NAME}|DNAT" || true
}

add_forward() {
  local proto="$1" ext="$2" guest="$3" inner="$4"
  local comment
  [[ "$proto" == "tcp" || "$proto" == "udp" ]] || { echo "协议只能是 tcp 或 udp"; exit 1; }
  comment="GRE-GW ${proto}:${ext}->${guest}:${inner}"
  iptables -t nat -C PREROUTING -i "$WAN_IF" -p "$proto" --dport "$ext" -m comment --comment "$comment" -j DNAT --to-destination "${guest}:${inner}" 2>/dev/null || \
    iptables -t nat -A PREROUTING -i "$WAN_IF" -p "$proto" --dport "$ext" -m comment --comment "$comment" -j DNAT --to-destination "${guest}:${inner}"
  iptables -C FORWARD -i "$WAN_IF" -o "$GRE_NAME" -p "$proto" -d "$guest" --dport "$inner" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$WAN_IF" -o "$GRE_NAME" -p "$proto" -d "$guest" --dport "$inner" -m comment --comment "$comment" -j ACCEPT
  echo "已添加: ${proto} ${GATEWAY_PUBLIC_IP}:${ext} -> ${guest}:${inner}"
}

del_forward() {
  local proto="$1" ext="$2" guest="$3" inner="$4"
  local comment="GRE-GW ${proto}:${ext}->${guest}:${inner}"
  while iptables -t nat -D PREROUTING -i "$WAN_IF" -p "$proto" --dport "$ext" -m comment --comment "$comment" -j DNAT --to-destination "${guest}:${inner}" 2>/dev/null; do :; done
  while iptables -D FORWARD -i "$WAN_IF" -o "$GRE_NAME" -p "$proto" -d "$guest" --dport "$inner" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; do :; done
  echo "已删除: ${proto} ${GATEWAY_PUBLIC_IP}:${ext} -> ${guest}:${inner}"
}

case "${1:-}" in
  on|enable|start) systemctl enable --now gre-gateway.service gre-gateway-check.timer ;;
  off|disable|stop) systemctl disable --now gre-gateway-check.timer gre-gateway.service ;;
  restart) /usr/local/bin/gre-gateway-restart ;;
  repair|check) /usr/local/sbin/gre-gateway-check ;;
  logs) journalctl -u gre-gateway.service -u gre-gateway-check.service --no-pager "${@:2}" ;;
  status) status ;;
  list) iptables -t nat -S PREROUTING | grep -E 'GRE-GW|GRE-GW-RANGE' || true ;;
  add) shift; [[ $# -eq 4 ]] || { usage; exit 1; }; add_forward "$@" ;;
  del|delete|rm) shift; [[ $# -eq 4 ]] || { usage; exit 1; }; del_forward "$@" ;;
  *) usage; exit 1 ;;
esac
EOF
chmod +x "$HELPER_BIN"

cat > "$RESTART_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl restart gre-gateway.service
systemctl enable --now gre-gateway-check.timer >/dev/null
systemctl start gre-gateway-check.service >/dev/null 2>&1 || true
gre-gw status
EOF
chmod +x "$RESTART_BIN"

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=GRE optimized gateway
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
Description=GRE optimized gateway self-healing check
After=network-online.target gre-gateway.service
Wants=network-online.target gre-gateway.service

[Service]
Type=oneshot
ExecStart=${CHECK_BIN}
EOF

cat > "$CHECK_TIMER_FILE" <<'EOF'
[Unit]
Description=Run GRE optimized gateway self-healing check

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true
Unit=gre-gateway-check.service

[Install]
WantedBy=timers.target
EOF

echo "==> 启动 GRE 网关"
systemctl daemon-reload
systemctl enable gre-gateway.service >/dev/null
systemctl restart gre-gateway.service
systemctl enable --now gre-gateway-check.timer >/dev/null
systemctl start gre-gateway-check.service >/dev/null 2>&1 || true

echo
echo "============================================================"
echo " GRE 优化线路网关配置完成"
echo "------------------------------------------------------------"
echo " 优化节点公网: ${GATEWAY_PUBLIC_IP}"
echo " 普通节点公网: ${BACKEND_RESOLVED_IP}"
echo " GRE:          ${GATEWAY_TUN_IP}/30 -> ${BACKEND_TUN_IP}/30"
echo " 小鸡网段:     ${GUEST_SUBNET}"
echo " MTU/MSS:      MTU ${GRE_MTU}, TCP MSS ${TCP_MSS}"
echo " 预转发端口:   ${PREFORWARD_ENABLE} (${PREFORWARD_RANGE})"
echo "------------------------------------------------------------"
echo " 一键开关:"
echo "   sudo gre-gw on"
echo "   sudo gre-gw off"
echo "   sudo gre-gw restart"
echo "   sudo gre-gw repair"
echo " 添加端口转发示例:"
echo "   sudo gre-gw add tcp 25022 10.10.0.123 22"
echo " 预转发说明:"
echo "   默认已将优化节点 ${PREFORWARD_RANGE} TCP/UDP 透传到普通节点 GRE IP，同端口保留。"
echo "   面板用户创建同范围端口后，无需再手动 gre-gw add。"
echo " 状态检查:"
echo "   sudo gre-gw status"
echo "   sudo gre-gw logs -n 80"
echo "============================================================"
