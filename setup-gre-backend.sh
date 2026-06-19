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
REMOVE_BIN="/usr/local/sbin/gre-backend-remove"
CHECK_BIN="/usr/local/sbin/gre-backend-check"
HELPER_BIN="/usr/local/bin/gre-be"
RESTART_BIN="/usr/local/bin/gre-backend-restart"
UNIT_FILE="/etc/systemd/system/gre-backend.service"
CHECK_UNIT_FILE="/etc/systemd/system/gre-backend-check.service"
CHECK_TIMER_FILE="/etc/systemd/system/gre-backend-check.timer"

GRE_NAME="${GRE_NAME:-gre-opt}"
GRE_TABLE="${GRE_TABLE:-2010}"
GRE_RULE_PREF="${GRE_RULE_PREF:-2010}"
GATEWAY_TUN_IP="${GATEWAY_TUN_IP:-10.255.0.1}"
BACKEND_TUN_IP="${BACKEND_TUN_IP:-10.255.0.2}"
GRE_MTU="${GRE_MTU:-1280}"
TCP_MSS="${TCP_MSS:-1240}"
GUEST_SUBNET="${GUEST_SUBNET:-}"
INCUS_BRIDGE="${INCUS_BRIDGE:-}"
GATEWAY_PUBLIC_IP="${GATEWAY_PUBLIC_IP:-}"
BACKEND_PUBLIC_IP="${BACKEND_PUBLIC_IP:-}"
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
  local log_file="/tmp/gre-backend-apt-update.log"
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

if [[ -z "$GATEWAY_PUBLIC_IP" ]]; then
  echo "优化线路节点地址说明: 填用户入口所在优化线路机器的公网 IPv4 或 A 记录域名。"
  read -rp "优化线路节点公网 IPv4/域名: " GATEWAY_PUBLIC_IP
fi
[[ -n "$GATEWAY_PUBLIC_IP" && "$GATEWAY_PUBLIC_IP" != *:* ]] || { echo "优化节点地址无效，只支持 IPv4 或 A 记录域名"; exit 1; }

if [[ -z "$INCUS_BRIDGE" ]]; then
  echo "Incus bridge 说明: 通常是 incusbr0。小鸡网段来自这个网桥，不会额外创建新网段。"
  read -rp "Incus bridge 名称 [incusbr0]: " INCUS_BRIDGE
  INCUS_BRIDGE="${INCUS_BRIDGE:-incusbr0}"
fi

if [[ -z "$GUEST_SUBNET" ]]; then
  echo "小鸡网段说明: 填 ${INCUS_BRIDGE} 的 IPv4 CIDR，例如 10.10.0.0/22。"
  echo "查看命令: ip -4 addr show ${INCUS_BRIDGE}"
  read -rp "小鸡/Incus bridge 网段 [10.10.0.0/22]: " GUEST_SUBNET
  GUEST_SUBNET="${GUEST_SUBNET:-10.10.0.0/22}"
fi
normalize_guest_subnet

echo "==> 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt_update_with_repair
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
GATEWAY_ENDPOINT_HOST=${GATEWAY_PUBLIC_IP}
GATEWAY_PUBLIC_IP=${GATEWAY_RESOLVED_IP}
GATEWAY_TUN_IP=${GATEWAY_TUN_IP}
BACKEND_TUN_IP=${BACKEND_TUN_IP}
GRE_MTU=${GRE_MTU}
TCP_MSS=${TCP_MSS}
GUEST_SUBNET=${GUEST_SUBNET}
INCUS_BRIDGE=${INCUS_BRIDGE}
GRE_TABLE=${GRE_TABLE}
GRE_RULE_PREF=${GRE_RULE_PREF}
PREFORWARD_ENABLE=${PREFORWARD_ENABLE}
PREFORWARD_RANGE=${PREFORWARD_RANGE}
EOF
chmod 600 "$CONFIG_FILE"

cat > "$APPLY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gre-backend/config.env

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
  awk -v key="$key" -v value="$value" 'BEGIN{done=0} index($0,key"=")==1{print key"="value; done=1; next} {print} END{if(!done) print key"="value}' /etc/gre-backend/config.env > "$tmp"
  cat "$tmp" > /etc/gre-backend/config.env
  rm -f "$tmp"
}

current_wan="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
[[ -n "$current_wan" ]] && WAN_IF="$current_wan"
current_public="$(ip -4 -o addr show dev "$WAN_IF" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
[[ -n "$current_public" ]] && BACKEND_PUBLIC_IP="$current_public"
resolved_gateway="$(resolve_ipv4 "${GATEWAY_ENDPOINT_HOST:-$GATEWAY_PUBLIC_IP}" || true)"
[[ -n "$resolved_gateway" ]] && GATEWAY_PUBLIC_IP="$resolved_gateway"
set_config WAN_IF "$WAN_IF"
set_config BACKEND_PUBLIC_IP "$BACKEND_PUBLIC_IP"
set_config GATEWAY_PUBLIC_IP "$GATEWAY_PUBLIC_IP"

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
ip rule del from "$BACKEND_TUN_IP" table "$GRE_TABLE" pref "$((GRE_RULE_PREF + 1))" 2>/dev/null || true
ip rule add from "$BACKEND_TUN_IP" table "$GRE_TABLE" pref "$((GRE_RULE_PREF + 1))"
ip route flush cache 2>/dev/null || true

while iptables -t mangle -S FORWARD 2>/dev/null | grep -F -- "-o $GRE_NAME " | grep -F -- "-j TCPMSS" >/tmp/gre-be-mss-rule 2>/dev/null; do
  rule="$(cat /tmp/gre-be-mss-rule)"
  iptables -t mangle ${rule/-A/-D} 2>/dev/null || break
done
while iptables -t mangle -S FORWARD 2>/dev/null | grep -F -- "-i $GRE_NAME " | grep -F -- "-j TCPMSS" >/tmp/gre-be-mss-rule 2>/dev/null; do
  rule="$(cat /tmp/gre-be-mss-rule)"
  iptables -t mangle ${rule/-A/-D} 2>/dev/null || break
done
rm -f /tmp/gre-be-mss-rule

iptables -C INPUT -p 47 -s "$GATEWAY_PUBLIC_IP" -j ACCEPT 2>/dev/null || iptables -I INPUT -p 47 -s "$GATEWAY_PUBLIC_IP" -j ACCEPT
iptables -C FORWARD -i "$INCUS_BRIDGE" -o "$GRE_NAME" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$INCUS_BRIDGE" -o "$GRE_NAME" -j ACCEPT
iptables -C FORWARD -i "$GRE_NAME" -o "$INCUS_BRIDGE" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$GRE_NAME" -o "$INCUS_BRIDGE" -j ACCEPT
iptables -t nat -C POSTROUTING -s "$GUEST_SUBNET" -o "$GRE_NAME" -j RETURN 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s "$GUEST_SUBNET" -o "$GRE_NAME" -j RETURN
iptables -t mangle -C FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -C FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

if [[ "${PREFORWARD_ENABLE:-1}" == "1" ]]; then
  for proto in tcp udp; do
    comment="GRE-BE-RANGE ${proto}:${PREFORWARD_RANGE}"
    iptables -C INPUT -i "$GRE_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -i "$GRE_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT
  done
fi
EOF
chmod +x "$APPLY_BIN"

cat > "$CHECK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gre-backend/config.env

repair=0

need_repair() {
  repair=1
  logger -t gre-backend-check "$*"
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
resolved_gateway="$(resolve_ipv4 "${GATEWAY_ENDPOINT_HOST:-$GATEWAY_PUBLIC_IP}" || true)"

[[ -n "$current_wan" && "$current_wan" != "${WAN_IF:-}" ]] && need_repair "WAN interface changed: ${WAN_IF:-unknown} -> ${current_wan}"
[[ -n "$current_public" && "$current_public" != "${BACKEND_PUBLIC_IP:-}" ]] && need_repair "backend public IPv4 changed: ${BACKEND_PUBLIC_IP:-unknown} -> ${current_public}"
[[ -n "$resolved_gateway" && "$resolved_gateway" != "${GATEWAY_PUBLIC_IP:-}" ]] && need_repair "gateway endpoint changed: ${GATEWAY_PUBLIC_IP:-unknown} -> ${resolved_gateway}"

ip link show "$GRE_NAME" >/dev/null 2>&1 || need_repair "GRE interface missing"
ip route show table "$GRE_TABLE" | grep -Eq "^default via ${GATEWAY_TUN_IP} dev ${GRE_NAME}( |$)" || need_repair "missing optimized default route"
ip route show table "$GRE_TABLE" | grep -F "$GUEST_SUBNET" | grep -F "dev $INCUS_BRIDGE" >/dev/null || need_repair "missing guest subnet route"
ip rule show | grep -F "from $GUEST_SUBNET lookup $GRE_TABLE" >/dev/null || need_repair "missing guest subnet ip rule"
ip rule show | grep -F "from $BACKEND_TUN_IP lookup $GRE_TABLE" >/dev/null || need_repair "missing backend tunnel ip rule"
iptables -C INPUT -p 47 -s "${resolved_gateway:-$GATEWAY_PUBLIC_IP}" -j ACCEPT 2>/dev/null || need_repair "missing GRE input rule"
iptables -C FORWARD -i "$INCUS_BRIDGE" -o "$GRE_NAME" -j ACCEPT 2>/dev/null || need_repair "missing guest to GRE forward rule"
iptables -C FORWARD -i "$GRE_NAME" -o "$INCUS_BRIDGE" -j ACCEPT 2>/dev/null || need_repair "missing GRE to guest forward rule"
iptables -t nat -C POSTROUTING -s "$GUEST_SUBNET" -o "$GRE_NAME" -j RETURN 2>/dev/null || need_repair "missing NAT return rule"
iptables -t mangle -C FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || need_repair "missing outbound TCPMSS rule"
iptables -t mangle -C FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || need_repair "missing inbound TCPMSS rule"

if [[ "${PREFORWARD_ENABLE:-1}" == "1" ]]; then
  for proto in tcp udp; do
    comment="GRE-BE-RANGE ${proto}:${PREFORWARD_RANGE}"
    iptables -C INPUT -i "$GRE_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || need_repair "missing ${proto} range INPUT rule"
  done
fi

if (( repair )); then
  /usr/local/sbin/gre-backend-apply
fi
EOF
chmod +x "$CHECK_BIN"

cat > "$REMOVE_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gre-backend/config.env

while iptables -t mangle -D FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TCP_MSS" 2>/dev/null; do :; done
while iptables -t mangle -D FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$TCP_MSS" 2>/dev/null; do :; done
while iptables -t mangle -D FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
while iptables -t mangle -D FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
while iptables -t nat -D POSTROUTING -s "$GUEST_SUBNET" -o "$GRE_NAME" -j RETURN 2>/dev/null; do :; done
for proto in tcp udp; do
  comment="GRE-BE-RANGE ${proto}:${PREFORWARD_RANGE}"
  while iptables -D INPUT -i "$GRE_NAME" -p "$proto" -d "$BACKEND_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; do :; done
done
while iptables -D FORWARD -i "$GRE_NAME" -o "$INCUS_BRIDGE" -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -i "$INCUS_BRIDGE" -o "$GRE_NAME" -j ACCEPT 2>/dev/null; do :; done
while iptables -D INPUT -p 47 -s "$GATEWAY_PUBLIC_IP" -j ACCEPT 2>/dev/null; do :; done

ip rule del from "$BACKEND_TUN_IP" table "$GRE_TABLE" pref "$((GRE_RULE_PREF + 1))" 2>/dev/null || true
ip rule del from "$GUEST_SUBNET" table "$GRE_TABLE" pref "$GRE_RULE_PREF" 2>/dev/null || true
ip route flush table "$GRE_TABLE" 2>/dev/null || true
ip route flush cache 2>/dev/null || true
ip tunnel del "$GRE_NAME" 2>/dev/null || true
EOF
chmod +x "$REMOVE_BIN"

cat > "$HELPER_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gre-backend/config.env

usage() {
  cat <<USAGE
用法:
  sudo gre-be on
  sudo gre-be off
  sudo gre-be restart
  sudo gre-be repair
  sudo gre-be status
  sudo gre-be logs

说明:
  这个命令运行在普通 Incus 节点，只控制小鸡走优化线路网关的 GRE 隧道。
  默认放行来自 GRE 的 ${PREFORWARD_RANGE} TCP/UDP 预转发流量，配合面板端口转发使用。
  off 会关闭 GRE、删除小鸡源地址策略路由和核心防火墙规则，宿主机默认出口保持原线路。
USAGE
}

status() {
  systemctl is-active gre-backend.service 2>/dev/null || true
  ip -brief addr show "$GRE_NAME" 2>/dev/null || true
  ip rule show | grep -F "lookup ${GRE_TABLE}" || true
  ip route show table "$GRE_TABLE" 2>/dev/null || true
  echo "pre-forward: ${PREFORWARD_ENABLE:-1} ${PREFORWARD_RANGE:-}"
  iptables -S | grep -E "${GRE_NAME}|${INCUS_BRIDGE}|${GATEWAY_PUBLIC_IP}" || true
  iptables -t nat -S POSTROUTING | grep -E "${GRE_NAME}|${GUEST_SUBNET}" || true
}

case "${1:-}" in
  on|enable|start) systemctl enable --now gre-backend.service gre-backend-check.timer ;;
  off|disable|stop) systemctl disable --now gre-backend-check.timer gre-backend.service ;;
  restart) /usr/local/bin/gre-backend-restart ;;
  repair|check) /usr/local/sbin/gre-backend-check ;;
  logs) journalctl -u gre-backend.service -u gre-backend-check.service --no-pager "${@:2}" ;;
  status) status ;;
  *) usage; exit 1 ;;
esac
EOF
chmod +x "$HELPER_BIN"

cat > "$RESTART_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl restart gre-backend.service
systemctl enable --now gre-backend-check.timer >/dev/null
systemctl start gre-backend-check.service >/dev/null 2>&1 || true
gre-be status
EOF
chmod +x "$RESTART_BIN"

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=GRE backend for optimized gateway
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
Description=GRE backend self-healing check
After=network-online.target gre-backend.service
Wants=network-online.target gre-backend.service

[Service]
Type=oneshot
ExecStart=${CHECK_BIN}
EOF

cat > "$CHECK_TIMER_FILE" <<'EOF'
[Unit]
Description=Run GRE backend self-healing check

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true
Unit=gre-backend-check.service

[Install]
WantedBy=timers.target
EOF

echo "==> 启动 GRE 后端"
systemctl daemon-reload
systemctl enable gre-backend.service >/dev/null
systemctl restart gre-backend.service
systemctl enable --now gre-backend-check.timer >/dev/null
systemctl start gre-backend-check.service >/dev/null 2>&1 || true

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
echo " 预转发端口:   ${PREFORWARD_ENABLE} (${PREFORWARD_RANGE})"
echo "------------------------------------------------------------"
echo " 一键开关:"
echo "   sudo gre-be on"
echo "   sudo gre-be off"
echo "   sudo gre-be restart"
echo "   sudo gre-be repair"
echo " 检查:"
echo "   sudo gre-be status"
echo "   sudo gre-be logs -n 80"
echo "   ip addr show ${GRE_NAME}"
echo "   ip rule show | grep ${GRE_TABLE}"
echo "   ping -c 3 ${GATEWAY_TUN_IP}"
echo "============================================================"
