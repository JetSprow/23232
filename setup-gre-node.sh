#!/usr/bin/env bash
# 普通节点 GRE 对接脚本（节点端 / node）
# 运行位置: 创建小鸡的普通 Incus 节点。
# 作用: 与家宽出口建立 GRE 隧道，用策略路由让小鸡(GUEST_SUBNET)走家宽出口出网，
#       宿主机自身默认出口保持原线路不变。
#       与旧版 setup-gre-backend.sh 并存（设备名/网段/路由表/状态目录均不同）。
# 用法:
#   sudo bash setup-gre-node.sh
#   sudo HOME_PUBLIC_IP=1.2.3.4 GUEST_SUBNET=10.10.0.0/22 GRE_MTU=1476 bash setup-gre-node.sh
set -euo pipefail
trap 'echo "[ERROR] 脚本在第 ${LINENO} 行退出: ${BASH_COMMAND}" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "需要 root 权限 (sudo)"; exit 1; }
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu"; exit 1; }

STATE_DIR="/etc/gre-node"
CONFIG_FILE="$STATE_DIR/config.env"
APPLY_BIN="/usr/local/sbin/gre-node-apply"
REMOVE_BIN="/usr/local/sbin/gre-node-remove"
CHECK_BIN="/usr/local/sbin/gre-node-check"
HELPER_BIN="/usr/local/bin/gre-node"
RESTART_BIN="/usr/local/bin/gre-node-restart"
UNIT_FILE="/etc/systemd/system/gre-node.service"
CHECK_UNIT_FILE="/etc/systemd/system/gre-node-check.service"
CHECK_TIMER_FILE="/etc/systemd/system/gre-node-check.timer"
SYSCTL_FILE="/etc/sysctl.d/98-gre-node.conf"

GRE_NAME="${GRE_NAME:-gre-link}"
GRE_TABLE="${GRE_TABLE:-2011}"
GRE_RULE_PREF="${GRE_RULE_PREF:-2011}"
HOME_TUN_IP="${HOME_TUN_IP:-10.255.1.1}"
NODE_TUN_IP="${NODE_TUN_IP:-10.255.1.2}"
GRE_MTU="${GRE_MTU:-}"            # 留空则自动探测；建议直接用家宽端打印出来的值
GRE_TXQLEN="${GRE_TXQLEN:-2000}"
GUEST_SUBNET="${GUEST_SUBNET:-}"
INCUS_BRIDGE="${INCUS_BRIDGE:-}"
HOME_PUBLIC_IP="${HOME_PUBLIC_IP:-}"
NODE_PUBLIC_IP="${NODE_PUBLIC_IP:-}"
PREFORWARD_ENABLE="${PREFORWARD_ENABLE:-1}"
PREFORWARD_RANGE="${PREFORWARD_RANGE:-20000:30000}"
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

probe_path_mtu() {
  local target="$1" lo=1200 hi=1472 best=0 mid
  ping -c1 -W2 "$target" >/dev/null 2>&1 || { echo 0; return; }
  while (( lo <= hi )); do
    mid=$(( (lo + hi) / 2 ))
    if ping -c1 -W2 -M do -s "$mid" "$target" >/dev/null 2>&1; then
      best=$mid; lo=$(( mid + 1 ))
    else
      hi=$(( mid - 1 ))
    fi
  done
  if (( best > 0 )); then echo $(( best + 28 )); else echo 0; fi
}

decide_mtu() {
  if [[ -n "$GRE_MTU" ]]; then echo "==> 使用指定 GRE MTU: ${GRE_MTU}"; return; fi
  echo "==> 探测到家宽出口的路径 MTU (DF ping ${HOME_PUBLIC_IP}) ..."
  local path_mtu; path_mtu="$(probe_path_mtu "$HOME_PUBLIC_IP")"
  if (( path_mtu >= 1400 )); then
    GRE_MTU=$(( path_mtu - 24 ))
    echo "    实测路径 MTU=${path_mtu}, GRE 开销 24B -> GRE MTU=${GRE_MTU}"
  else
    echo "    路径 MTU 探测失败(ICMP 可能被过滤)，请手动选择:"
    echo "      1) 干净以太网 1500  -> GRE MTU 1476 (默认)"
    echo "      2) PPPoE/拨号 1492  -> GRE MTU 1468 (留 8B 余量)"
    local pick=""; read -rp "    选择 [1]: " pick || pick=""
    case "${pick:-1}" in 2) GRE_MTU=1468 ;; *) GRE_MTU=1476 ;; esac
    echo "    采用 GRE MTU=${GRE_MTU}"
  fi
  echo "    注意: 两端 GRE MTU 必须一致，建议直接填家宽端打印出来的值。"
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

apt_update_with_repair() {
  local log_file="/tmp/gre-node-apt-update.log"
  if apt-get update -qq >"$log_file" 2>&1; then rm -f "$log_file"; return 0; fi
  if grep -qi 'bullseye-backports.*Release file' "$log_file"; then
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

if [[ -z "$HOME_PUBLIC_IP" ]]; then
  echo "家宽出口地址说明: 填家宽出口机的公网 IPv4 或 A 记录域名。"
  read -rp "家宽出口公网 IPv4/域名: " HOME_PUBLIC_IP
fi
valid_ip_or_host "$HOME_PUBLIC_IP" || { echo "家宽出口地址无效，只支持 IPv4 或 A 记录域名"; exit 1; }

if [[ -z "$INCUS_BRIDGE" ]]; then
  echo "Incus bridge 说明: 通常是 incusbr0。小鸡网段来自这个网桥。"
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
apt-get install -y -qq iproute2 iptables iputils-ping curl ca-certificates

WAN_IF="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
[[ -n "$WAN_IF" ]] || { echo "无法识别默认出口网卡"; exit 1; }

if [[ -z "$NODE_PUBLIC_IP" ]]; then
  NODE_PUBLIC_IP="$(ip -4 -o addr show dev "$WAN_IF" scope global | awk '{split($4,a,"/"); print a[1]; exit}')"
fi
[[ -n "$NODE_PUBLIC_IP" ]] || { echo "无法识别普通节点本机 IPv4"; exit 1; }

HOME_RESOLVED_IP="$HOME_PUBLIC_IP"
if [[ ! "$HOME_PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  HOME_RESOLVED_IP="$(getent ahostsv4 "$HOME_PUBLIC_IP" | awk '{print $1; exit}')"
fi
[[ -n "$HOME_RESOLVED_IP" ]] || { echo "无法解析家宽出口 IPv4: $HOME_PUBLIC_IP"; exit 1; }

decide_mtu

echo "==> 写入配置"
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
cat > "$CONFIG_FILE" <<EOF
GRE_NAME=${GRE_NAME}
WAN_IF=${WAN_IF}
NODE_PUBLIC_IP=${NODE_PUBLIC_IP}
HOME_ENDPOINT_HOST=${HOME_PUBLIC_IP}
HOME_PUBLIC_IP=${HOME_RESOLVED_IP}
HOME_TUN_IP=${HOME_TUN_IP}
NODE_TUN_IP=${NODE_TUN_IP}
GRE_MTU=${GRE_MTU}
GRE_TXQLEN=${GRE_TXQLEN}
GUEST_SUBNET=${GUEST_SUBNET}
INCUS_BRIDGE=${INCUS_BRIDGE}
GRE_TABLE=${GRE_TABLE}
GRE_RULE_PREF=${GRE_RULE_PREF}
PREFORWARD_ENABLE=${PREFORWARD_ENABLE}
PREFORWARD_RANGE=${PREFORWARD_RANGE}
RMEM_MAX=${RMEM_MAX}
WMEM_MAX=${WMEM_MAX}
EOF
chmod 600 "$CONFIG_FILE"

cat > "$APPLY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gre-node/config.env

resolve_ipv4() {
  local host="$1"
  [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { printf '%s\n' "$host"; return 0; }
  getent ahostsv4 "$host" | awk '{print $1; exit}'
}
set_config() {
  local key="$1" value="$2" tmp; tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" 'BEGIN{done=0} index($0,key"=")==1{print key"="value; done=1; next} {print} END{if(!done) print key"="value}' /etc/gre-node/config.env > "$tmp"
  cat "$tmp" > /etc/gre-node/config.env; rm -f "$tmp"
}

current_wan="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
[[ -n "$current_wan" ]] && WAN_IF="$current_wan"
current_public="$(ip -4 -o addr show dev "$WAN_IF" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
[[ -n "$current_public" ]] && NODE_PUBLIC_IP="$current_public"
resolved_home="$(resolve_ipv4 "${HOME_ENDPOINT_HOST:-$HOME_PUBLIC_IP}" || true)"
[[ -n "$resolved_home" ]] && HOME_PUBLIC_IP="$resolved_home"
set_config WAN_IF "$WAN_IF"
set_config NODE_PUBLIC_IP "$NODE_PUBLIC_IP"
set_config HOME_PUBLIC_IP "$HOME_PUBLIC_IP"

cat > /etc/sysctl.d/98-gre-node.conf <<SYSCTL
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
sysctl -q --system >/dev/null 2>&1 || sysctl -q -p /etc/sysctl.d/98-gre-node.conf >/dev/null 2>&1 || true
sysctl -qw net.ipv4.ip_forward=1 >/dev/null

ip tunnel del "$GRE_NAME" 2>/dev/null || true
ip tunnel add "$GRE_NAME" mode gre local "$NODE_PUBLIC_IP" remote "$HOME_PUBLIC_IP" ttl 255
ip addr add "${NODE_TUN_IP}/30" dev "$GRE_NAME"
ip link set "$GRE_NAME" mtu "$GRE_MTU" txqueuelen "${GRE_TXQLEN:-2000}" up
sysctl -qw "net.ipv4.conf.${GRE_NAME//./\/}.rp_filter=2" >/dev/null 2>&1 || true
sysctl -qw "net.ipv4.conf.${INCUS_BRIDGE//./\/}.rp_filter=2" >/dev/null 2>&1 || true

# 策略路由：仅小鸡网段走家宽出口；宿主机自身默认路由不动
ip route replace "$GUEST_SUBNET" dev "$INCUS_BRIDGE" table "$GRE_TABLE"
ip route replace default via "$HOME_TUN_IP" dev "$GRE_NAME" table "$GRE_TABLE"
ip rule del from "$GUEST_SUBNET" table "$GRE_TABLE" pref "$GRE_RULE_PREF" 2>/dev/null || true
ip rule add from "$GUEST_SUBNET" table "$GRE_TABLE" pref "$GRE_RULE_PREF"
ip rule del from "$NODE_TUN_IP" table "$GRE_TABLE" pref "$((GRE_RULE_PREF + 1))" 2>/dev/null || true
ip rule add from "$NODE_TUN_IP" table "$GRE_TABLE" pref "$((GRE_RULE_PREF + 1))"
# 入站连接回程原路返回：带标记 0x1 的包查 main 表，从节点 WAN 出去（修复入站端口/SSH 握手失败）。
# 优先级必须高于上面的小鸡出向规则（pref 数字更小先匹配）。
ip rule del fwmark 0x1/0x1 lookup main pref "$((GRE_RULE_PREF - 1))" 2>/dev/null || true
ip rule add fwmark 0x1/0x1 lookup main pref "$((GRE_RULE_PREF - 1))"
ip route flush cache 2>/dev/null || true

while iptables -t mangle -S FORWARD 2>/dev/null | grep -F -- "-o $GRE_NAME " | grep -F -- "-j TCPMSS" >/tmp/gre-node-mss 2>/dev/null; do
  rule="$(cat /tmp/gre-node-mss)"; iptables -t mangle ${rule/-A/-D} 2>/dev/null || break
done
while iptables -t mangle -S FORWARD 2>/dev/null | grep -F -- "-i $GRE_NAME " | grep -F -- "-j TCPMSS" >/tmp/gre-node-mss 2>/dev/null; do
  rule="$(cat /tmp/gre-node-mss)"; iptables -t mangle ${rule/-A/-D} 2>/dev/null || break
done
rm -f /tmp/gre-node-mss

iptables -C INPUT -p 47 -s "$HOME_PUBLIC_IP" -j ACCEPT 2>/dev/null || iptables -I INPUT -p 47 -s "$HOME_PUBLIC_IP" -j ACCEPT
iptables -C FORWARD -i "$INCUS_BRIDGE" -o "$GRE_NAME" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$INCUS_BRIDGE" -o "$GRE_NAME" -j ACCEPT
iptables -C FORWARD -i "$GRE_NAME" -o "$INCUS_BRIDGE" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$GRE_NAME" -o "$INCUS_BRIDGE" -j ACCEPT
# 入站连接放行：客户端经节点 WAN 进来再 DNAT 到小鸡，及其回程。
iptables -C FORWARD -i "$WAN_IF" -o "$INCUS_BRIDGE" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$WAN_IF" -o "$INCUS_BRIDGE" -j ACCEPT
iptables -C FORWARD -i "$INCUS_BRIDGE" -o "$WAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$INCUS_BRIDGE" -o "$WAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
# connmark：从节点 WAN 进来的新连接打标 0x1，并把连接标记恢复到每个包上。
# 配合上面 "fwmark 0x1 lookup main" 规则，让入站连接的回程包原路从节点 WAN 出去，
# 而小鸡主动发起的连接无此标记，仍落到 table 2011 走家宽出口。修复入站端口/SSH 握手失败。
iptables -t mangle -C PREROUTING -i "$WAN_IF" -m conntrack --ctstate NEW -j CONNMARK --set-mark 0x1 2>/dev/null || iptables -t mangle -A PREROUTING -i "$WAN_IF" -m conntrack --ctstate NEW -j CONNMARK --set-mark 0x1
iptables -t mangle -C PREROUTING -j CONNMARK --restore-mark 2>/dev/null || iptables -t mangle -A PREROUTING -j CONNMARK --restore-mark
# 小鸡出向不在本机做 SNAT（由家宽出口端 SNAT），这里 RETURN 跳过本机 NAT
iptables -t nat -C POSTROUTING -s "$GUEST_SUBNET" -o "$GRE_NAME" -j RETURN 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s "$GUEST_SUBNET" -o "$GRE_NAME" -j RETURN
iptables -t mangle -C FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -C FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

if [[ "${PREFORWARD_ENABLE:-1}" == "1" ]]; then
  for proto in tcp udp; do
    comment="GRE-NODE-RANGE ${proto}:${PREFORWARD_RANGE}"
    iptables -C INPUT -i "$GRE_NAME" -p "$proto" -d "$NODE_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -i "$GRE_NAME" -p "$proto" -d "$NODE_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT
  done
fi
EOF
chmod +x "$APPLY_BIN"

cat > "$CHECK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gre-node/config.env
repair=0
need_repair() { repair=1; logger -t gre-node-check "$*"; }
resolve_ipv4() {
  local host="$1"
  [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { printf '%s\n' "$host"; return 0; }
  getent ahostsv4 "$host" | awk '{print $1; exit}'
}
current_wan="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
current_public=""; [[ -n "$current_wan" ]] && current_public="$(ip -4 -o addr show dev "$current_wan" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
resolved_home="$(resolve_ipv4 "${HOME_ENDPOINT_HOST:-$HOME_PUBLIC_IP}" || true)"
[[ -n "$current_wan" && "$current_wan" != "${WAN_IF:-}" ]] && need_repair "WAN changed: ${WAN_IF:-?} -> ${current_wan}"
[[ -n "$current_public" && "$current_public" != "${NODE_PUBLIC_IP:-}" ]] && need_repair "node public IP changed: ${NODE_PUBLIC_IP:-?} -> ${current_public}"
[[ -n "$resolved_home" && "$resolved_home" != "${HOME_PUBLIC_IP:-}" ]] && need_repair "home endpoint changed: ${HOME_PUBLIC_IP:-?} -> ${resolved_home}"
ip link show "$GRE_NAME" >/dev/null 2>&1 || need_repair "GRE interface missing"
ip route show table "$GRE_TABLE" | grep -Eq "^default via ${HOME_TUN_IP} dev ${GRE_NAME}( |$)" || need_repair "missing default route in table"
ip route show table "$GRE_TABLE" | grep -F "$GUEST_SUBNET" | grep -F "dev $INCUS_BRIDGE" >/dev/null || need_repair "missing guest route in table"
ip rule show | grep -F "from $GUEST_SUBNET lookup $GRE_TABLE" >/dev/null || need_repair "missing guest ip rule"
ip rule show | grep -F "from $NODE_TUN_IP lookup $GRE_TABLE" >/dev/null || need_repair "missing tunnel ip rule"
ip rule show | grep -F "lookup main" | grep -F "0x1" >/dev/null || need_repair "missing inbound fwmark rule"
iptables -C INPUT -p 47 -s "${resolved_home:-$HOME_PUBLIC_IP}" -j ACCEPT 2>/dev/null || need_repair "missing GRE input rule"
iptables -C FORWARD -i "$INCUS_BRIDGE" -o "$GRE_NAME" -j ACCEPT 2>/dev/null || need_repair "missing guest->GRE forward"
iptables -C FORWARD -i "$GRE_NAME" -o "$INCUS_BRIDGE" -j ACCEPT 2>/dev/null || need_repair "missing GRE->guest forward"
iptables -C FORWARD -i "$WAN_IF" -o "$INCUS_BRIDGE" -j ACCEPT 2>/dev/null || need_repair "missing WAN->guest forward"
iptables -C FORWARD -i "$INCUS_BRIDGE" -o "$WAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || need_repair "missing guest->WAN return forward"
iptables -t mangle -C PREROUTING -i "$WAN_IF" -m conntrack --ctstate NEW -j CONNMARK --set-mark 0x1 2>/dev/null || need_repair "missing connmark set"
iptables -t mangle -C PREROUTING -j CONNMARK --restore-mark 2>/dev/null || need_repair "missing connmark restore"
iptables -t nat -C POSTROUTING -s "$GUEST_SUBNET" -o "$GRE_NAME" -j RETURN 2>/dev/null || need_repair "missing NAT return"
iptables -t mangle -C FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || need_repair "missing outbound MSS"
iptables -t mangle -C FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || need_repair "missing inbound MSS"
if [[ "${PREFORWARD_ENABLE:-1}" == "1" ]]; then
  for proto in tcp udp; do
    comment="GRE-NODE-RANGE ${proto}:${PREFORWARD_RANGE}"
    iptables -C INPUT -i "$GRE_NAME" -p "$proto" -d "$NODE_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || need_repair "missing ${proto} range INPUT"
  done
fi
(( repair )) && /usr/local/sbin/gre-node-apply
EOF
chmod +x "$CHECK_BIN"

cat > "$REMOVE_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gre-node/config.env
while iptables -t mangle -D FORWARD -o "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
while iptables -t mangle -D FORWARD -i "$GRE_NAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
while iptables -t mangle -D PREROUTING -i "$WAN_IF" -m conntrack --ctstate NEW -j CONNMARK --set-mark 0x1 2>/dev/null; do :; done
while iptables -t mangle -D PREROUTING -j CONNMARK --restore-mark 2>/dev/null; do :; done
while iptables -t nat -D POSTROUTING -s "$GUEST_SUBNET" -o "$GRE_NAME" -j RETURN 2>/dev/null; do :; done
for proto in tcp udp; do
  comment="GRE-NODE-RANGE ${proto}:${PREFORWARD_RANGE}"
  while iptables -D INPUT -i "$GRE_NAME" -p "$proto" -d "$NODE_TUN_IP" --dport "$PREFORWARD_RANGE" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; do :; done
done
while iptables -D FORWARD -i "$INCUS_BRIDGE" -o "$WAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -i "$WAN_IF" -o "$INCUS_BRIDGE" -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -i "$GRE_NAME" -o "$INCUS_BRIDGE" -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -i "$INCUS_BRIDGE" -o "$GRE_NAME" -j ACCEPT 2>/dev/null; do :; done
while iptables -D INPUT -p 47 -s "$HOME_PUBLIC_IP" -j ACCEPT 2>/dev/null; do :; done
ip rule del fwmark 0x1/0x1 lookup main pref "$((GRE_RULE_PREF - 1))" 2>/dev/null || true
ip rule del from "$NODE_TUN_IP" table "$GRE_TABLE" pref "$((GRE_RULE_PREF + 1))" 2>/dev/null || true
ip rule del from "$GUEST_SUBNET" table "$GRE_TABLE" pref "$GRE_RULE_PREF" 2>/dev/null || true
ip route flush table "$GRE_TABLE" 2>/dev/null || true
ip route flush cache 2>/dev/null || true
ip tunnel del "$GRE_NAME" 2>/dev/null || true
EOF
chmod +x "$REMOVE_BIN"

cat > "$HELPER_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/gre-node/config.env
usage() {
  cat <<USAGE
用法:
  sudo gre-node on|off|restart|repair|status|logs
  sudo gre-node mtu            # 重新探测路径 MTU 并应用（两端需一致）
说明:
  本机是普通 Incus 节点，仅小鸡网段 ${GUEST_SUBNET} 经 GRE 走家宽出口，
  宿主机自身默认出口保持原线路。
USAGE
}
status() {
  systemctl is-active gre-node.service 2>/dev/null || true
  ip -brief addr show "$GRE_NAME" 2>/dev/null || true
  echo "MTU: $(cat /sys/class/net/${GRE_NAME}/mtu 2>/dev/null || echo '?')"
  ip rule show | grep -F "lookup ${GRE_TABLE}" || true
  ip route show table "$GRE_TABLE" 2>/dev/null || true
  echo "pre-forward: ${PREFORWARD_ENABLE:-1} ${PREFORWARD_RANGE:-}"
  iptables -S | grep -E "${GRE_NAME}|${INCUS_BRIDGE}|${HOME_PUBLIC_IP}" || true
}
remtu() {
  local lo=1200 hi=1472 best=0 mid path newmtu
  ping -c1 -W2 "$HOME_PUBLIC_IP" >/dev/null 2>&1 || { echo "对端不可达，保持当前 MTU"; exit 1; }
  while (( lo <= hi )); do mid=$(( (lo+hi)/2 ))
    if ping -c1 -W2 -M do -s "$mid" "$HOME_PUBLIC_IP" >/dev/null 2>&1; then best=$mid; lo=$((mid+1)); else hi=$((mid-1)); fi
  done
  (( best > 0 )) || { echo "探测失败，保持当前 MTU"; exit 1; }
  path=$(( best + 28 )); newmtu=$(( path - 24 ))
  awk -v v="$newmtu" 'index($0,"GRE_MTU=")==1{print "GRE_MTU="v; next}{print}' /etc/gre-node/config.env > /tmp/gre-node.cfg && cat /tmp/gre-node.cfg > /etc/gre-node/config.env && rm -f /tmp/gre-node.cfg
  echo "探测路径 MTU=${path} -> GRE MTU=${newmtu}（确保家宽端也设为同值），应用中..."
  /usr/local/sbin/gre-node-apply; gre-node status
}
case "${1:-}" in
  on|enable|start) systemctl enable --now gre-node.service gre-node-check.timer ;;
  off|disable|stop) systemctl disable --now gre-node-check.timer gre-node.service ;;
  restart) /usr/local/bin/gre-node-restart ;;
  repair|check) /usr/local/sbin/gre-node-check ;;
  mtu) remtu ;;
  logs) journalctl -u gre-node.service -u gre-node-check.service --no-pager "${@:2}" ;;
  status) status ;;
  *) usage; exit 1 ;;
esac
EOF
chmod +x "$HELPER_BIN"

cat > "$RESTART_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl restart gre-node.service
systemctl enable --now gre-node-check.timer >/dev/null
systemctl start gre-node-check.service >/dev/null 2>&1 || true
gre-node status
EOF
chmod +x "$RESTART_BIN"

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=GRE node uplink to home egress
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
Description=GRE node self-healing check
After=network-online.target gre-node.service
Wants=network-online.target gre-node.service

[Service]
Type=oneshot
ExecStart=${CHECK_BIN}
EOF

cat > "$CHECK_TIMER_FILE" <<'EOF'
[Unit]
Description=Run GRE node self-healing check

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true
Unit=gre-node-check.service

[Install]
WantedBy=timers.target
EOF

echo "==> 启动 GRE 节点对接"
systemctl daemon-reload
systemctl enable gre-node.service >/dev/null
systemctl restart gre-node.service
systemctl enable --now gre-node-check.timer >/dev/null
systemctl start gre-node-check.service >/dev/null 2>&1 || true

echo
echo "============================================================"
echo " GRE 普通节点对接配置完成"
echo "------------------------------------------------------------"
echo " 普通节点公网: ${NODE_PUBLIC_IP}"
echo " 家宽出口公网: ${HOME_RESOLVED_IP}"
echo " GRE 隧道:     ${NODE_TUN_IP}/30 <-> ${HOME_TUN_IP}/30  (设备 ${GRE_NAME})"
echo " GRE MTU:      ${GRE_MTU}  (两端必须一致；MSS 自动 clamp)"
echo " 小鸡网段:     ${GUEST_SUBNET}  经隧道走家宽出口"
echo " Incus Bridge: ${INCUS_BRIDGE}"
echo " 路由表/规则:  table ${GRE_TABLE} / pref ${GRE_RULE_PREF}"
echo "------------------------------------------------------------"
echo " 验证隧道连通: ping -c3 ${HOME_TUN_IP}"
echo " 验证小鸡出口IP(进任一小鸡内执行): curl -4 ifconfig.me"
echo "   预期返回家宽出口公网 ${HOME_RESOLVED_IP}"
echo " 管理命令: gre-node on|off|restart|repair|status|logs|mtu"
echo "============================================================"
