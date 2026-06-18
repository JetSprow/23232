#!/usr/bin/env bash
# GRE 链路一键诊断（只读，不改任何配置）
# 自动识别本机角色（家宽出口端 gre-home / 普通节点端 gre-node），打印定位断点所需的全部状态。
# 用法: 在【两台机器上分别】运行，把各自完整输出发回。
#   curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/gre-diag.sh -o gre-diag.sh && sudo bash gre-diag.sh
set -uo pipefail

C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_0=$'\033[0m'
hr(){ printf '%s\n' "------------------------------------------------------------"; }
sec(){ echo; hr; echo "## $*"; hr; }
ok(){ echo "${C_OK}[OK]${C_0} $*"; }
bad(){ echo "${C_BAD}[!!]${C_0} $*"; }
warn(){ echo "${C_WARN}[? ]${C_0} $*"; }
run(){ echo "${C_DIM}\$ $*${C_0}"; eval "$@" 2>&1 | sed 's/^/   /'; }

[[ $EUID -eq 0 ]] || { echo "需要 root: sudo bash gre-diag.sh"; exit 1; }

ROLE=""
[[ -f /etc/gre-home/config.env ]] && ROLE="home"
[[ -f /etc/gre-node/config.env ]] && ROLE="${ROLE:+both}${ROLE:-node}"
[[ -z "$ROLE" ]] && ROLE="none"

echo "============================================================"
echo " GRE 链路诊断  $(date '+%F %T')"
echo " 主机: $(hostname)   内核: $(uname -r)"
echo " 角色检测: ${ROLE}   (home=家宽出口 node=普通节点)"
echo "============================================================"

# ---------- 通用：内核/网卡/防火墙后端 ----------
sec "通用内核与网络后端"
fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
[[ "$fwd" == "1" ]] && ok "ip_forward=1" || bad "ip_forward=$fwd  (必须为1，否则不转发)"
echo "rp_filter(all/default): $(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)/$(sysctl -n net.ipv4.conf.default.rp_filter 2>/dev/null)  (建议2，0也可，1严格会丢非对称回包)"
echo "拥塞控制/qdisc: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)/$(sysctl -n net.core.default_qdisc 2>/dev/null)"
if command -v nft >/dev/null && nft list ruleset 2>/dev/null | grep -qiE 'masquerade|snat'; then
  warn "检测到 nftables 里有 masquerade/snat 规则（可能是 incus 自带，会抢在 iptables 之前改写源IP）:"
  run "nft list ruleset 2>/dev/null | grep -iE 'masquerade|snat|table (ip|inet)' | head -40"
else
  echo "nftables 无 masquerade/snat 规则（或未用 nft）"
fi
echo "iptables 后端: $(iptables -V 2>/dev/null)"

diag_common_iface(){
  local cfg="$1"; source "$cfg"
  sec "[$ROLE] 配置文件 $cfg"
  run "cat $cfg"
  sec "[$ROLE] GRE 接口 $GRE_NAME"
  if ip link show "$GRE_NAME" >/dev/null 2>&1; then
    ok "接口存在"
    run "ip -br addr show $GRE_NAME"
    echo "MTU: $(cat /sys/class/net/$GRE_NAME/mtu 2>/dev/null)  txqlen: $(cat /sys/class/net/$GRE_NAME/tx_queue_len 2>/dev/null)"
    run "ip -s link show $GRE_NAME | grep -A2 -E 'RX:|TX:'"
  else
    bad "GRE 接口 $GRE_NAME 不存在！隧道没建起来"
  fi
}

# ---------- 家宽出口端 ----------
if [[ "$ROLE" == "home" || "$ROLE" == "both" ]]; then
  diag_common_iface /etc/gre-home/config.env
  source /etc/gre-home/config.env
  sec "[home] 对端可达性 + 隧道内 ping"
  run "ping -c2 -W2 $NODE_PUBLIC_IP"
  run "ping -c2 -W2 $NODE_TUN_IP"
  sec "[home] SNAT 规则（关键：-s 必须匹配小鸡网段 $GUEST_SUBNET）"
  snat=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -E "SNAT|MASQUERADE")
  echo "$snat" | sed 's/^/   /'
  if echo "$snat" | grep -q "$GUEST_SUBNET"; then
    ok "存在针对 $GUEST_SUBNET 的 SNAT/MASQUERADE"
  else
    bad "没有匹配 $GUEST_SUBNET 的 SNAT！小鸡包带私网源IP出网，有去无回 —— 这是最常见断网原因"
    echo "   现有出口网卡 WAN_IF=${WAN_IF}  家宽公网=${HOME_PUBLIC_IP}"
  fi
  sec "[home] FORWARD 放行"
  run "iptables -S FORWARD | grep -E '$GRE_NAME|$WAN_IF' || echo '（无相关规则）'"
  sec "[home] 小鸡出网连接跟踪（看小鸡的包有没有被本机SNAT记录）"
  if command -v conntrack >/dev/null; then
    run "conntrack -L 2>/dev/null | grep -E 'src=10\\.' | head -15 || echo '（暂无 10.x 源连接，让小鸡持续 ping 1.1.1.1 再跑一次）'"
  else
    warn "未装 conntrack，跳过（apt install -y conntrack 可补）"
  fi
  sec "[home] 实时抓包（8秒）：现在让任一小鸡持续 ping 1.1.1.1，观察包是否进隧道并被SNAT后发出"
  echo ">>> 隧道入口 gre-link 上的 ICMP（应看到 src=10.10.x.x dst=1.1.1.1 进来）:"
  timeout 8 tcpdump -ni "$GRE_NAME" icmp 2>/dev/null | sed 's/^/   /' || true
  echo ">>> WAN 出口 $WAN_IF 上发往 1.1.1.1 的 ICMP（src 应已变成家宽公网 ${HOME_PUBLIC_IP}，且有回包）:"
  timeout 8 tcpdump -ni "$WAN_IF" "icmp and host 1.1.1.1" 2>/dev/null | sed 's/^/   /' || true
fi

# ---------- 普通节点端 ----------
if [[ "$ROLE" == "node" || "$ROLE" == "both" ]]; then
  diag_common_iface /etc/gre-node/config.env
  source /etc/gre-node/config.env
  sec "[node] 对端可达性 + 隧道内 ping"
  run "ping -c2 -W2 $HOME_PUBLIC_IP"
  run "ping -c2 -W2 $HOME_TUN_IP"
  sec "[node] 策略路由规则 ip rule（关键）"
  rules=$(ip rule show)
  echo "$rules" | sed 's/^/   /'
  echo "$rules" | grep -qF "from $GUEST_SUBNET lookup $GRE_TABLE" && ok "小鸡出向规则在 (from $GUEST_SUBNET -> table $GRE_TABLE)" || bad "缺小鸡出向规则"
  echo "$rules" | grep -q "0x1.*lookup main" && ok "入站回程 fwmark 规则在 (0x1 -> main)" || bad "缺 fwmark 0x1 -> main（入站握手会失败）"
  sec "[node] 路由表 $GRE_TABLE"
  run "ip route show table $GRE_TABLE"
  sec "[node] 小鸡出向选路验证（应为 dev $GRE_NAME，不能是 WAN 网卡）"
  run "ip route get 1.1.1.1 from 10.10.0.1 iif $INCUS_BRIDGE 2>&1 || ip route get 1.1.1.1 from 10.10.0.1"
  sec "[node] NAT POSTROUTING（关键：小鸡->GRE 必须 RETURN 跳过本机NAT，且要在 incus MASQUERADE 之前）"
  run "iptables -t nat -S POSTROUTING"
  if iptables -t nat -S POSTROUTING | grep -q "incusbr0\|incus"; then
    warn "存在 incus 自带 NAT 规则，确认上面的 RETURN 行号在 incus MASQUERADE 之前，否则小鸡包会被改源IP"
  fi
  sec "[node] connmark（入站回程标记）"
  run "iptables -t mangle -S PREROUTING | grep -E 'CONNMARK|0x1' || echo '（缺 connmark 规则）'"
  sec "[node] FORWARD 放行"
  run "iptables -S FORWARD | grep -E '$GRE_NAME|$INCUS_BRIDGE|$WAN_IF' || echo '（无相关规则）'"
  sec "[node] incus 网络配置（看是否自带 ipv4.nat）"
  if command -v incus >/dev/null; then
    run "incus network show $INCUS_BRIDGE 2>/dev/null | grep -E 'ipv4|nat' || echo '（读不到，可能名字不同）'"
  fi
fi

if [[ "$ROLE" == "none" ]]; then
  bad "本机既无 /etc/gre-home 也无 /etc/gre-node 配置，GRE 脚本没装或装失败。"
fi

sec "诊断完成"
echo "把以上【完整输出】发回。两台机器都要跑。"
echo "重点看：home端有没有匹配小鸡网段的SNAT、抓包里小鸡的包出WAN时源IP变没变；"
echo "        node端 ip route get 是不是走 $([ -n "${GRE_NAME:-}" ] && echo "$GRE_NAME" || echo gre-link)、有没有 incus 的 nft/iptables NAT 在抢流量。"
