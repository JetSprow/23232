#!/usr/bin/env bash
# 家宽出口 GRE 脚本（出口端 / egress）
# 运行位置: 有独立公网 IP 的家宽出口机器。
# 作用: 与普通节点建立 GRE 隧道，普通节点上的小鸡流量经隧道从本机家宽公网 IP 出网。
#       与旧版 setup-gre-gateway.sh 并存（设备名/网段/路由表/状态目录均不同）。
# 用法:
#   sudo bash setup-gre-home.sh
#   sudo NODE_PUBLIC_IP=1.2.3.4 GUEST_SUBNET=10.10.0.0/22 bash setup-gre-home.sh
set -euo pipefail
trap 'echo "[ERROR] 脚本在第 ${LINENO} 行退出: ${BASH_COMMAND}" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "需要 root 权限 (sudo)"; exit 1; }
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu"; exit 1; }

STATE_DIR="/etc/gre-home"
CONFIG_FILE="$STATE_DIR/config.env"
APPLY_BIN="/usr/local/sbin/gre-home-apply"
REMOVE_BIN="/usr/local/sbin/gre-home-remove"
CHECK_BIN="/usr/local/sbin/gre-home-check"
HELPER_BIN="/usr/local/bin/gre-home"
RESTART_BIN="/usr/local/bin/gre-home-restart"
UNIT_FILE="/etc/systemd/system/gre-home.service"
CHECK_UNIT_FILE="/etc/systemd/system/gre-home-check.service"
CHECK_TIMER_FILE="/etc/systemd/system/gre-home-check.timer"
SYSCTL_FILE="/etc/sysctl.d/98-gre-home.conf"

GRE_NAME="${GRE_NAME:-gre-link}"
HOME_TUN_IP="${HOME_TUN_IP:-10.255.1.1}"
NODE_TUN_IP="${NODE_TUN_IP:-10.255.1.2}"
GRE_MTU="${GRE_MTU:-}"            # 留空则自动探测路径 MTU
GRE_TXQLEN="${GRE_TXQLEN:-2000}"
GUEST_SUBNET="${GUEST_SUBNET:-}"
NODE_PUBLIC_IP="${NODE_PUBLIC_IP:-}"
HOME_PUBLIC_IP="${HOME_PUBLIC_IP:-}"
WAN_IF="${WAN_IF:-}"
PREFORWARD_ENABLE="${PREFORWARD_ENABLE:-1}"
PREFORWARD_RANGE="${PREFORWARD_RANGE:-20000:30000}"
# 缓冲区上限：16MB 足够在 ~130ms RTT 下单流跑满千兆，不无脑拉到 64M（弱机浪费内存）
RMEM_MAX="${RMEM_MAX:-16777216}"
WMEM_MAX="${WMEM_MAX:-16777216}"

valid_ip_or_host() { [[ -n "$1" && "$1" != *:* ]]; }

normalize_cidr() {
  local cidr="$1" ip prefix a b c d ipnum mask net
  if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    echo "CIDR 格式无效: $cidr" >&2; return 1
  fi
  ip="${cidr%/*}"; prefix="${cidr#*/}"
  IFS=. read -r a b c d <<<"$ip"
  for part in "$a" "$b" "$c" "$d"; do
    ((part >= 0 && part <= 255)) || { echo "CIDR 地址段超出范围: $cidr" >&2; return 1; }
  done
  ((prefix >= 0 && prefix <= 32)) || { echo "CIDR 掩码超出范围: $cidr" >&2; return 1; }
  ipnum=$(((a << 24) | (b << 16) | (c << 8) | d))
  if ((prefix == 0)); then mask=0; else mask=$(((0xffffffff << (32 - prefix)) & 0xffffffff)); fi
  net=$((ipnum & mask))
  printf "%d.%d.%d.%d/%d\n" "$(((net >> 24) & 255))" "$(((net >> 16) & 255))" "$(((net >> 8) & 255))" "$((net & 255))" "$prefix"
}

normalize_guest_subnet() {
  local normalized
  normalized="$(normalize_cidr "$GUEST_SUBNET")" || exit 1
  [[ "$normalized" != "$GUEST_SUBNET" ]] && echo "小鸡网段已规范化: ${GUEST_SUBNET} -> ${normalized}"
  GUEST_SUBNET="$normalized"
}

# DF ping 二分探测到目标的路径 MTU；返回完整路径 MTU（含 IP+ICMP 头），失败返回 0
probe_path_mtu() {
  local target="$1" lo=1200 hi=1472 best=0 mid
  ping -c1 -W2 "$target" >/dev/null 2>&1 || { echo 0; return; }
  while (( lo <= hi )); do
    mid=$(( (lo + hi) / 2 ))
    if ping -c1 -W2 -M do -s "$mid" "$target" >/dev/null 2>&1 \
       || ping -c1 -W2 -M do -s "$mid" "$target" >/dev/null 2>&1; then
      best=$mid; lo=$(( mid + 1 ))
    else
      hi=$(( mid - 1 ))
    fi
  done
  if (( best > 0 )); then echo $(( best + 28 )); else echo 0; fi
}

decide_mtu() {
  # 已显式指定则尊重用户
  if [[ -n "$GRE_MTU" ]]; then
    echo "==> 使用指定 GRE MTU: ${GRE_MTU}"; return
  fi
  echo "==> 探测到普通节点的路径 MTU (DF ping ${NODE_PUBLIC_IP}) ..."
  local path_mtu; path_mtu="$(probe_path_mtu "$NODE_PUBLIC_IP")"
  if (( path_mtu >= 1400 )); then
    GRE_MTU=$(( path_mtu - 24 ))
    echo "    实测路径 MTU=${path_mtu}, GRE 开销 24B -> GRE MTU=${GRE_MTU}"
  else
    echo "    路径 MTU 探测失败(ICMP 可能被过滤)，请手动选择底层链路类型:"
    echo "      1) 干净以太网 1500  -> GRE MTU 1476 (默认)"
    echo "      2) PPPoE/拨号 1492  -> GRE MTU 1468 (留 8B 余量)"
    local pick=""
    read -rp "    选择 [1]: " pick || pick=""
    case "${pick:-1}" in
      2) GRE_MTU=1468 ;;
      *) GRE_MTU=1476 ;;
    esac
    echo "    采用 GRE MTU=${GRE_MTU}"
  fi
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
      *) sed -i '/bullseye-backports/s/^[[:space:]]*\(deb\|deb-src\)[[:space:]]/# disabled by gre setup: &/' "$file"; echo "   patched:  ${file}" ;;
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
  local log_file="/tmp/gre-home-apt-update.log"
  if apt-get update -qq >"$log_file" 2>&1; then rm -f "$log_file"; return 0; fi
  if disable_broken_apt_repos "$log_file"; then
    if apt-get update -qq >"$log_file" 2>&1; then rm -f "$log_file"; return 0; fi
  fi
  if grep -qi 'bullseye-backports' "$log_file"; then
    cat "$log_file" >&2; disable_broken_backports_repo
    if ! apt-get update -qq; then
      echo "仍然存在异常 APT 源，请检查:" >&2
      grep -Ril 'bullseye-backports' /etc/apt 2>/dev/null >&2 || true
      return 1
    fi
    rm -f "$log_file"; return 0
  fi
  cat "$log_file" >&2; rm -f "$log_file"; return 1
}

if [[ -z "$NODE_PUBLIC_IP" ]]; then
  echo "普通节点地址说明: 填小鸡所在普通机器的公网 IPv4 或 A 记录域名。"
  read -rp "普通节点公网 IPv4/域名: " NODE_PUBLIC_IP
fi
valid_ip_or_host "$NODE_PUBLIC_IP" || { echo "普通节点地址无效，只支持 IPv4 或 A 记录域名"; exit 1; }

if [[ -z "$GUEST_SUBNET" ]]; then
  echo "小鸡网段说明: 填普通节点 incusbr0 正在使用的 IPv4 网段（用于 SNAT 出口）。"
  read -rp "小鸡/Incus bridge 网段 [10.10.0.0/22]: " GUEST_SUBNET
  GUEST_SUBNET="${GUEST_SUBNET:-10.10.0.0/22}"
fi
normalize_guest_subnet

echo "==> 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt_update_with_repair
apt-get install -y -qq iproute2 iptables iputils-ping curl ca-certificates

WAN_IF="${WAN_IF:-$(ip -4 route show default | awk '/default/ {print $5; exit}')}"
[[ -n "$WAN_IF" ]] || { echo "无法识别默认出口网卡"; exit 1; }

if [[ -z "$HOME_PUBLIC_IP" ]]; then
  HOME_PUBLIC_IP="$(ip -4 -o addr show dev "$WAN_IF" scope global | awk '{split($4,a,"/"); print a[1]; exit}')"
fi
[[ -n "$HOME_PUBLIC_IP" ]] || { echo "无法识别家宽出口本机 IPv4"; exit 1; }

NODE_RESOLVED_IP="$NODE_PUBLIC_IP"
if [[ ! "$NODE_PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  NODE_RESOLVED_IP="$(getent ahostsv4 "$NODE_PUBLIC_IP" | awk '{print $1; exit}')"
fi
[[ -n "$NODE_RESOLVED_IP" ]] || { echo "无法解析普通节点 IPv4: $NODE_PUBLIC_IP"; exit 1; }

decide_mtu

echo "==> 写入配置"
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
cat > "$CONFIG_FILE" <<EOF
GRE_NAME=${GRE_NAME}
WAN_IF=${WAN_IF}
HOME_PUBLIC_IP=${HOME_PUBLIC_IP}
NODE_ENDPOINT_HOST=${NODE_PUBLIC_IP}
NODE_PUBLIC_IP=${NODE_RESOLVED_IP}
HOME_TUN_IP=${HOME_TUN_IP}
NODE_TUN_IP=${NODE_TUN_IP}
GRE_MTU=${GRE_MTU}
GRE_TXQLEN=${GRE_TXQLEN}
GUEST_SUBNET=${GUEST_SUBNET}
PREFORWARD_ENABLE=${PREFORWARD_ENABLE}
PREFORWARD_RANGE=${PREFORWARD_RANGE}
RMEM_MAX=${RMEM_MAX}
WMEM_MAX=${WMEM_MAX}
EOF
chmod 600 "$CONFIG_FILE"

cat > "$APPLY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gre-home/config.env

resolve_ipv4() {
  local host="$1"
  [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { printf '%s\n' "$host"; return 0; }
  getent ahostsv4 "$host" | awk '{print $1; exit}'
}
set_config() {
  local key="$1" value="$2" tmp; tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" 'BEGIN{done=0} index($0,key"=")==1{print key"="value; done=1; next} {print} END{if(!done) print key"="value}' /etc/gre-home/config.env > "$tmp"
  cat "$tmp" > /etc/gre-home/config.env; rm -f "$tmp"
}

current_wan="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
[[ -n "$current_wan" ]] && WAN_IF="$current_wan"
current_public="$(ip -4 -o addr show dev "$WAN_IF" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
[[ -n "$current_public" ]] && HOME_PUBLIC_IP="$current_public"
resolved_node="$(resolve_ipv4 "${NODE_ENDPOINT_HOST:-$NODE_PUBLIC_IP}" || true)"
[[ -n "$resolved_node" ]] && NODE_PUBLIC_IP="$resolved_node"
set_config WAN_IF "$WAN_IF"
set_config HOME_PUBLIC_IP "$HOME_PUBLIC_IP"
set_config NODE_PUBLIC_IP "$NODE_PUBLIC_IP"

# 内核网络调优：转发 + BBR/fq + 大缓冲区 + 放松 rp_filter（策略路由是非对称的）
cat > /etc/sysctl.d/98-gre-home.conf <<SYSCTL
net.ipv4.ip_forward=1
net.core.rmem_max=${RMEM_MAX}
net.core.wmem_max=${WMEM_MAX}
net.ipv4.tcp_rmem=4096 131072 ${RMEM_MAX}
net.ipv4.tcp_wmem=4096 131072 ${WMEM_MAX}
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
SYSCTL
sysctl -q --system >/dev/null 2>&1 || sysctl -q -p /etc/sysctl.d/98-gre-home.conf >/dev/null 2>&1 || true
sysctl -qw net.ipv4.ip_forward=1 >/dev/null

ip tunnel del "$GRE_NAME" 2>/dev/null || true
ip tunnel add "$GRE_NAME" mode gre local "$HOME_PUBLIC_IP" remote "$NODE_PUBLIC_IP" ttl 255
ip addr add "${HOME_TUN_IP}/30" dev "$GRE_NAME"
ip link set "$GRE_NAME" mtu "$GRE_MTU" txqueuelen "${GRE_TXQLEN:-2000}" up
sysctl -qw "net.ipv4.conf.${GRE_NAME//./\/}.rp_filter=2" >/dev/null 2>&1 || true
ip route replace "$GUEST_SUBNET" via "$NODE_TUN_IP" dev "$GRE_NAME"

# 清理本设备旧的 MSS 规则后重建（始终用 clamp-mss-to-pmtu 跟随 MTU）
while iptables -t mangle -S FORWARD 2>/dev/null | grep -F -- "-o $GRE_NAME " | grep -F -- "-j TCPMSS" >/tmp/gre-home-mss 2>/dev/null; do
  rule="$(cat /tmp/gre-home-mss)"; iptables -t mangle ${rule/-A/-D} 2>/dev/null || break
done
while iptables -t mangle -S FORWARD 2>/dev/null | grep -F -- "-i $GRE_NAME " | grep -F -- "-j TCPMSS" >/tmp/gre-home-mss 2>/dev/null; do
  rule="$(cat /tmp/gre-home-mss)"; iptables -t mangle ${rule/-A/-D} 2>/dev/null || break
done
rm -f /tmp/gre-home-mss

iptables -C INPUT -p 47 -s "$NODE_PUBLIC_IP" -j ACCEPT 2>/dev/null || iptables -I INPUT -p 47 -s "$NODE_PUBLIC_IP" -j ACCEPT
iptables -C FORWARD -i "$GRE_NAME" -o "$WAN_IF" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$GRE_NAME" -o "$WAN_IF" -j ACCEPT
iptables -C FORWARD -i "$WAN_IF" -o "$GRE_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$WAN_IF" -o "$GRE_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -C POSTROUTING -s "$GUEST_SUBNET" -o "$WAN_IF" -j SNAT --to-source "$HOME_PUBLIC_IP" 2>/dev/null || iptables -t nat -A POSTROUTING -s "$GUEST_SUBNET" -o "$WAN_IF" -j SNAT --to-source "$HOME_PUBLIC_IP"
iptables -t mangle -C FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -C FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

if [[ "${PREFORWARD_ENABLE:-1}" == "1" ]]; then
  for proto in tcp udp; do
    comment="GRE-HOME-RANGE ${proto}:${PREFORWARD_RANGE}->${NODE_TUN_IP}"
    iptables -t nat -C PREROUTING -i "$WAN_IF" -p "$proto" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j DNAT --to-destination "$NODE_TUN_IP" 2>/dev/null || \
      iptables -t nat -A PREROUTING -i "$WAN_IF" -p "$proto" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j DNAT --to-destination "$NODE_TUN_IP"
    iptables -C FORWARD -i "$WAN_IF" -o "$GRE_NAME" -p "$proto" -d "$NODE_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || \
      iptables -A FORWARD -i "$WAN_IF" -o "$GRE_NAME" -p "$proto" -d "$NODE_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT
  done
fi
EOF
chmod +x "$APPLY_BIN"

cat > "$CHECK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gre-home/config.env
repair=0
need_repair() { repair=1; logger -t gre-home-check "$*"; }
resolve_ipv4() {
  local host="$1"
  [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { printf '%s\n' "$host"; return 0; }
  getent ahostsv4 "$host" | awk '{print $1; exit}'
}
current_wan="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
current_public=""; [[ -n "$current_wan" ]] && current_public="$(ip -4 -o addr show dev "$current_wan" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
resolved_node="$(resolve_ipv4 "${NODE_ENDPOINT_HOST:-$NODE_PUBLIC_IP}" || true)"
[[ -n "$current_wan" && "$current_wan" != "${WAN_IF:-}" ]] && need_repair "WAN changed: ${WAN_IF:-?} -> ${current_wan}"
[[ -n "$current_public" && "$current_public" != "${HOME_PUBLIC_IP:-}" ]] && need_repair "home public IP changed: ${HOME_PUBLIC_IP:-?} -> ${current_public}"
[[ -n "$resolved_node" && "$resolved_node" != "${NODE_PUBLIC_IP:-}" ]] && need_repair "node endpoint changed: ${NODE_PUBLIC_IP:-?} -> ${resolved_node}"
ip link show "$GRE_NAME" >/dev/null 2>&1 || need_repair "GRE interface missing"
ip route show "$GUEST_SUBNET" | grep -F "via $NODE_TUN_IP" | grep -F "dev $GRE_NAME" >/dev/null || need_repair "missing guest route"
iptables -C INPUT -p 47 -s "${resolved_node:-$NODE_PUBLIC_IP}" -j ACCEPT 2>/dev/null || need_repair "missing GRE input rule"
iptables -C FORWARD -i "$GRE_NAME" -o "$WAN_IF" -j ACCEPT 2>/dev/null || need_repair "missing GRE->WAN forward"
iptables -C FORWARD -i "$WAN_IF" -o "$GRE_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || need_repair "missing WAN return forward"
iptables -t nat -C POSTROUTING -s "$GUEST_SUBNET" -o "$WAN_IF" -j SNAT --to-source "${current_public:-$HOME_PUBLIC_IP}" 2>/dev/null || need_repair "missing SNAT"
iptables -t mangle -C FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || need_repair "missing outbound MSS"
iptables -t mangle -C FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || need_repair "missing inbound MSS"
if [[ "${PREFORWARD_ENABLE:-1}" == "1" ]]; then
  for proto in tcp udp; do
    comment="GRE-HOME-RANGE ${proto}:${PREFORWARD_RANGE}->${NODE_TUN_IP}"
    iptables -t nat -C PREROUTING -i "$WAN_IF" -p "$proto" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j DNAT --to-destination "$NODE_TUN_IP" 2>/dev/null || need_repair "missing ${proto} range DNAT"
    iptables -C FORWARD -i "$WAN_IF" -o "$GRE_NAME" -p "$proto" -d "$NODE_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || need_repair "missing ${proto} range FORWARD"
  done
fi
(( repair )) && /usr/local/sbin/gre-home-apply
EOF
chmod +x "$CHECK_BIN"

cat > "$REMOVE_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gre-home/config.env
while iptables -t mangle -D FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
while iptables -t mangle -D FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
for proto in tcp udp; do
  comment="GRE-HOME-RANGE ${proto}:${PREFORWARD_RANGE}->${NODE_TUN_IP}"
  while iptables -t nat -D PREROUTING -i "$WAN_IF" -p "$proto" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j DNAT --to-destination "$NODE_TUN_IP" 2>/dev/null; do :; done
  while iptables -D FORWARD -i "$WAN_IF" -o "$GRE_NAME" -p "$proto" -d "$NODE_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; do :; done
done
while iptables -t nat -D POSTROUTING -s "$GUEST_SUBNET" -o "$WAN_IF" -j SNAT --to-source "$HOME_PUBLIC_IP" 2>/dev/null; do :; done
while iptables -D FORWARD -i "$WAN_IF" -o "$GRE_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -i "$GRE_NAME" -o "$WAN_IF" -j ACCEPT 2>/dev/null; do :; done
while iptables -D INPUT -p 47 -s "$NODE_PUBLIC_IP" -j ACCEPT 2>/dev/null; do :; done
ip route del "$GUEST_SUBNET" via "$NODE_TUN_IP" dev "$GRE_NAME" 2>/dev/null || true
ip tunnel del "$GRE_NAME" 2>/dev/null || true
EOF
chmod +x "$REMOVE_BIN"

cat > "$HELPER_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gre-home/config.env
usage() {
  cat <<USAGE
用法:
  sudo gre-home on|off|restart|repair|status|logs
  sudo gre-home add tcp|udp 外部端口 小鸡IP 内部端口
  sudo gre-home del tcp|udp 外部端口 小鸡IP 内部端口
  sudo gre-home mtu            # 重新探测路径 MTU 并应用
说明:
  本机是家宽出口端，小鸡流量经 GRE 从家宽公网 ${HOME_PUBLIC_IP} 出网。
  默认把 ${PREFORWARD_RANGE} 整段 TCP/UDP 预转发到普通节点 GRE IP，同端口保留。
USAGE
}
status() {
  systemctl is-active gre-home.service 2>/dev/null || true
  ip -brief addr show "$GRE_NAME" 2>/dev/null || true
  ip route show "$GUEST_SUBNET" 2>/dev/null || true
  echo "MTU: $(cat /sys/class/net/${GRE_NAME}/mtu 2>/dev/null || echo '?')  pre-forward: ${PREFORWARD_ENABLE:-1} ${PREFORWARD_RANGE:-}"
  iptables -t nat -S | grep -E "GRE-HOME|${GUEST_SUBNET}|${GRE_NAME}" || true
}
remtu() {
  local lo=1200 hi=1472 best=0 mid path
  ping -c1 -W2 "$NODE_PUBLIC_IP" >/dev/null 2>&1 || { echo "对端不可达，保持当前 MTU"; exit 1; }
  while (( lo <= hi )); do mid=$(( (lo+hi)/2 ))
    if ping -c1 -W2 -M do -s "$mid" "$NODE_PUBLIC_IP" >/dev/null 2>&1; then best=$mid; lo=$((mid+1)); else hi=$((mid-1)); fi
  done
  (( best > 0 )) || { echo "探测失败，保持当前 MTU"; exit 1; }
  path=$(( best + 28 )); local newmtu=$(( path - 24 ))
  awk -v v="$newmtu" 'index($0,"GRE_MTU=")==1{print "GRE_MTU="v; next}{print}' /etc/gre-home/config.env > /tmp/gre-home.cfg && cat /tmp/gre-home.cfg > /etc/gre-home/config.env && rm -f /tmp/gre-home.cfg
  echo "探测路径 MTU=${path} -> GRE MTU=${newmtu}，应用中..."
  /usr/local/sbin/gre-home-apply; gre-home status
}
add_forward() {
  local proto="$1" ext="$2" guest="$3" inner="$4" comment
  [[ "$proto" == "tcp" || "$proto" == "udp" ]] || { echo "协议只能是 tcp 或 udp"; exit 1; }
  comment="GRE-HOME ${proto}:${ext}->${guest}:${inner}"
  iptables -t nat -C PREROUTING -i "$WAN_IF" -p "$proto" --dport "$ext" -m comment --comment "$comment" -j DNAT --to-destination "${guest}:${inner}" 2>/dev/null || \
    iptables -t nat -A PREROUTING -i "$WAN_IF" -p "$proto" --dport "$ext" -m comment --comment "$comment" -j DNAT --to-destination "${guest}:${inner}"
  iptables -C FORWARD -i "$WAN_IF" -o "$GRE_NAME" -p "$proto" -d "$guest" --dport "$inner" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$WAN_IF" -o "$GRE_NAME" -p "$proto" -d "$guest" --dport "$inner" -m comment --comment "$comment" -j ACCEPT
  echo "已添加: ${proto} ${HOME_PUBLIC_IP}:${ext} -> ${guest}:${inner}"
}
del_forward() {
  local proto="$1" ext="$2" guest="$3" inner="$4" comment="GRE-HOME ${proto}:${ext}->${guest}:${inner}"
  while iptables -t nat -D PREROUTING -i "$WAN_IF" -p "$proto" --dport "$ext" -m comment --comment "$comment" -j DNAT --to-destination "${guest}:${inner}" 2>/dev/null; do :; done
  while iptables -D FORWARD -i "$WAN_IF" -o "$GRE_NAME" -p "$proto" -d "$guest" --dport "$inner" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; do :; done
  echo "已删除: ${proto} ${HOME_PUBLIC_IP}:${ext} -> ${guest}:${inner}"
}
case "${1:-}" in
  on|enable|start) systemctl enable --now gre-home.service gre-home-check.timer ;;
  off|disable|stop) systemctl disable --now gre-home-check.timer gre-home.service ;;
  restart) /usr/local/bin/gre-home-restart ;;
  repair|check) /usr/local/sbin/gre-home-check ;;
  mtu) remtu ;;
  logs) journalctl -u gre-home.service -u gre-home-check.service --no-pager "${@:2}" ;;
  status) status ;;
  add) shift; [[ $# -eq 4 ]] || { usage; exit 1; }; add_forward "$@" ;;
  del|delete|rm) shift; [[ $# -eq 4 ]] || { usage; exit 1; }; del_forward "$@" ;;
  *) usage; exit 1 ;;
esac
EOF
chmod +x "$HELPER_BIN"

cat > "$RESTART_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl restart gre-home.service
systemctl enable --now gre-home-check.timer >/dev/null
systemctl start gre-home-check.service >/dev/null 2>&1 || true
gre-home status
EOF
chmod +x "$RESTART_BIN"

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=GRE home egress tunnel
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
Description=GRE home egress self-healing check
After=network-online.target gre-home.service
Wants=network-online.target gre-home.service

[Service]
Type=oneshot
ExecStart=${CHECK_BIN}
EOF

cat > "$CHECK_TIMER_FILE" <<'EOF'
[Unit]
Description=Run GRE home egress self-healing check

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true
Unit=gre-home-check.service

[Install]
WantedBy=timers.target
EOF

echo "==> 启动 GRE 家宽出口"
systemctl daemon-reload
systemctl enable gre-home.service >/dev/null
systemctl restart gre-home.service
systemctl enable --now gre-home-check.timer >/dev/null
systemctl start gre-home-check.service >/dev/null 2>&1 || true

echo
echo "============================================================"
echo " GRE 家宽出口端配置完成"
echo "------------------------------------------------------------"
echo " 家宽出口公网: ${HOME_PUBLIC_IP}"
echo " 普通节点公网: ${NODE_RESOLVED_IP}"
echo " GRE 隧道:     ${HOME_TUN_IP}/30 <-> ${NODE_TUN_IP}/30  (设备 ${GRE_NAME})"
echo " GRE MTU:      ${GRE_MTU}  (MSS 自动 clamp 跟随)"
echo " 小鸡网段:     ${GUEST_SUBNET}  -> SNAT 到 ${HOME_PUBLIC_IP}"
echo " 预转发端口:   ${PREFORWARD_ENABLE} (${PREFORWARD_RANGE})"
echo "------------------------------------------------------------"
echo " 下一步：在【普通节点】上运行配对命令："
echo
echo "   sudo HOME_PUBLIC_IP=${HOME_PUBLIC_IP} \\"
echo "        GUEST_SUBNET=${GUEST_SUBNET} \\"
echo "        GRE_MTU=${GRE_MTU} \\"
echo "        bash setup-gre-node.sh"
echo
echo " 管理命令: gre-home on|off|restart|repair|status|logs|mtu"
echo " 隧道连通后两端互 ping: ping -c3 ${NODE_TUN_IP}"
echo "============================================================"
