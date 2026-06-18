#!/usr/bin/env bash
# =============================================================================
# wg-tune.sh — 交互式 WireGuard 隧道出口/中转 自测试 / 自分析 / 自调优
# =============================================================================
#
# 配套脚本:setup-wg-gateway.sh / setup-wg-backend.sh / setup-home-vps.sh
#           (隧道接口默认 wg-opt,Table=off + 手动路由 + iptables 转发)
#
# 目标:诊断 "WireGuard 隧道中转/出口跑不满线路" 的问题,定位到具体某层,
#       并在你确认后做最小化、可回滚的调优。
#
# 设计原则:
#   • 默认只读。所有"写"操作需手动选菜单 + 二次确认,且自动备份、可一键回滚。
#   • 不修改任何 setup-wg-*.sh,不动它们的 .conf / systemd 单元 / iptables 规则。
#   • 单流 vs 多流并发对比是核心判据:
#       并发≫单流 → 单连接窗口瓶颈(缓冲区/RTT) → 调缓冲区
#       并发≈单流 → 链路/MTU/CPU 瓶颈 → 看 MTU、单核 softirq、上游
#
# 用法:  sudo bash wg-tune.sh
#        curl -fsSL .../wg-tune.sh | sudo bash      (已处理管道 stdin)
#
# =============================================================================
set -uo pipefail

# ---- 默认值(可被环境变量覆盖,与 setup-wg-*.sh 对齐)-----------------------
WG_NAME="${WG_NAME:-wg-opt}"
INCUS_BRIDGE="${INCUS_BRIDGE:-incusbr0}"
SPEED_URL_DEFAULT="${SPEED_URL:-https://hil.proof.ovh.us/files/1Gb.dat}"
PARALLEL_STREAMS=4

BACKUP_DIR="/var/backups/wg-tune"
SYSCTL_DROPIN="/etc/sysctl.d/97-wg-tune.conf"

C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
C_YEL=$'\033[33m'; C_CYN=$'\033[36m'; C_BLD=$'\033[1m'

# ---- 工具函数 ---------------------------------------------------------------
need_root() {
  [[ "${EUID}" -eq 0 ]] || { echo "请用 root 运行:sudo bash $0" >&2; exit 1; }
}
hr()   { printf '%s\n' "------------------------------------------------------------"; }
ok()   { printf '  %s[OK]%s   %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '  %s[!!]%s   %s\n' "$C_YEL" "$C_RESET" "$*"; }
bad()  { printf '  %s[XX]%s   %s\n' "$C_RED" "$C_RESET" "$*"; }
info() { printf '  %s·%s    %s\n'   "$C_DIM" "$C_RESET" "$*"; }
title(){ printf '\n%s== %s ==%s\n'  "$C_BLD$C_CYN" "$*" "$C_RESET"; }
have() { command -v "$1" >/dev/null 2>&1; }

confirm() { local a; read -r -p "${1:-确认执行?} [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }

bps_human() {
  awk -v b="${1:-0}" 'BEGIN{ printf "%.1f Mbit/s (%.2f MB/s)", b*8/1000000, b/1048576 }'
}

# 找到当前真实存在的 wg 接口(优先 WG_NAME,否则取第一个)
detect_wg_iface() {
  WG_IF=""
  if have wg; then
    if wg show "$WG_NAME" >/dev/null 2>&1; then
      WG_IF="$WG_NAME"
    else
      WG_IF="$(wg show interfaces 2>/dev/null | tr ' ' '\n' | head -1)"
    fi
  fi
}

# =============================================================================
# 诊断 1:WireGuard 接口 / 内核态 vs 用户态 / handshake
# =============================================================================
diag_wg() {
  title "WireGuard 接口状态"
  if ! have wg; then bad "未安装 wireguard-tools(wg 命令缺失)"; return; fi
  detect_wg_iface
  if [[ -z "$WG_IF" ]]; then bad "没有活跃的 WireGuard 接口(WG_NAME=$WG_NAME 未起来)"; return; fi
  info "活跃接口:$WG_IF"

  # 内核态 vs 用户态:内核态会有 wireguard 模块;用户态是 wireguard-go 进程
  if lsmod 2>/dev/null | grep -qw wireguard; then
    ok "内核态 WireGuard(wireguard.ko 已加载,最快)"
    WG_USERSPACE=0
  elif pgrep -x wireguard-go >/dev/null 2>&1; then
    bad "用户态 wireguard-go 在跑!吞吐比内核态低数倍,且单核易打满。"
    info "  多见于老内核/容器。建议升级内核(≥5.6)用内核态 WireGuard。"
    WG_USERSPACE=1
  else
    warn "无法判定内核态/用户态(模块未列出但接口存在)。"
    WG_USERSPACE=-1
  fi

  # MTU
  local mtu; mtu=$(cat "/sys/class/net/$WG_IF/mtu" 2>/dev/null || echo "?")
  info "接口 MTU = $mtu"
  WG_MTU_NOW="$mtu"
  if [[ "$mtu" =~ ^[0-9]+$ ]]; then
    if (( mtu < 1380 )); then
      bad "MTU=$mtu 偏低。WG over IPv4 开销仅 60B,干净 1500 链路最优约 1420。"
      info "  过低 → 每包有效载荷少、pps 翻倍、加解密 CPU 负担加重。"
    elif (( mtu > 1440 )); then
      warn "MTU=$mtu 偏高,若底层有 PPPoE/再封装可能分片。"
    else
      ok "MTU=$mtu 合理"
    fi
  fi

  # handshake 时效 + 传输量
  title "WireGuard handshake / 传输统计"
  local now hs age peers
  peers=$(wg show "$WG_IF" peers 2>/dev/null)
  if [[ -z "$peers" ]]; then warn "无 peer。"; return; fi
  now=$(date +%s)
  while read -r pk; do
    [[ -z "$pk" ]] && continue
    hs=$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk -v k="$pk" '$1==k{print $2}')
    age=$(( now - ${hs:-0} ))
    if [[ "${hs:-0}" -eq 0 ]]; then
      bad "peer ${pk:0:12}… 从未握手(隧道没通!)"
    elif (( age > 180 )); then
      warn "peer ${pk:0:12}… 上次握手 ${age}s 前(可能已掉,会触发重连卡顿)"
    else
      ok "peer ${pk:0:12}… 握手正常(${age}s 前)"
    fi
  done <<< "$peers"
  echo
  wg show "$WG_IF" transfer 2>/dev/null | while read -r pk rx tx; do
    info "peer ${pk:0:12}…  rx=$rx  tx=$tx"
  done
}

# =============================================================================
# 诊断 2:内核缓冲区 / BBR / qdisc
# =============================================================================
diag_buffers() {
  title "内核 TCP 缓冲区 / 拥塞控制 / qdisc"
  local rmax wmax cc qdisc
  rmax=$(sysctl -n net.core.rmem_max 2>/dev/null)
  wmax=$(sysctl -n net.core.wmem_max 2>/dev/null)
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
  info "rmem_max=${rmax:-?}  wmem_max=${wmax:-?}"
  info "congestion=${cc:-?}  qdisc=${qdisc:-?}"

  BUF_SMALL=0; NO_BBR=0
  if [[ -n "$rmax" && "$rmax" -lt 8388608 ]]; then
    bad "rmem_max=${rmax}B (<8MB)。中转机若终结/转发长肥管道,会被窗口卡死。"
    BUF_SMALL=1
  else
    ok "缓冲区上限足够"
  fi
  if [[ "$cc" != "bbr" ]]; then
    bad "拥塞控制=${cc:-?}(非 bbr)。跨境有丢包时 cubic 稳态吞吐明显偏低。"
    NO_BBR=1
  else
    ok "拥塞控制=bbr"
  fi
  [[ "$qdisc" == "fq" ]] && ok "qdisc=fq" || warn "qdisc=${qdisc:-?}(建议 fq,配合 bbr)"
  info "注:纯三层转发流量不经本机 TCP socket,缓冲区主要影响 backend 落地的本地服务"
  info "    与 REDIRECT 端口转发;但 BBR/fq 对转发排队延迟普遍有益。"
}

# =============================================================================
# 诊断 3:rp_filter / 转发 / MSS clamp
# =============================================================================
diag_forward() {
  title "转发 / rp_filter / MSS clamp"
  local fwd; fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
  [[ "$fwd" == "1" ]] && ok "ip_forward=1" || bad "ip_forward=${fwd:-0}(转发必须为 1)"

  detect_wg_iface
  local r_all r_if
  r_all=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)
  info "rp_filter.all=${r_all:-?}"
  if [[ -n "$WG_IF" ]]; then
    r_if=$(sysctl -n "net.ipv4.conf.$WG_IF.rp_filter" 2>/dev/null)
    if [[ "${r_all:-1}" == "1" && "${r_if:-1}" == "1" ]]; then
      bad "rp_filter 严格(=1)。非对称路由(策略路由/隧道回包)会被丢→重传→掉速。"
    else
      ok "rp_filter 已放宽($WG_IF=${r_if:-?})"
    fi
  fi

  # MSS clamp(setup-wg-* 用 iptables mangle FORWARD)
  if iptables -t mangle -S FORWARD 2>/dev/null | grep -q 'TCPMSS'; then
    ok "检测到 FORWARD 链 TCPMSS clamp 规则"
  elif nft list ruleset 2>/dev/null | grep -qi 'tcp option maxseg'; then
    ok "检测到 nft MSS clamp"
  else
    warn "未发现 MSS clamp。隧道场景缺它会触发 PMTUD 黑洞→大包重传→掉速。"
  fi

  # home-vps 的字符串深度匹配会吃 CPU
  if iptables -S FORWARD 2>/dev/null | grep -q -- '--algo bm'; then
    warn "FORWARD 链有 '-m string --algo bm' 全包扫描(home-vps 的 BT 过滤)。"
    info "  高速转发时单核会被字符串匹配打满,直接限速。可考虑改端口/协议特征。"
  fi
}

# =============================================================================
# 诊断 4:CPU / 单核 softirq 瓶颈
# =============================================================================
diag_cpu() {
  title "CPU / 软中断(WG 加解密单核瓶颈)"
  local cores; cores=$(nproc 2>/dev/null || echo "?")
  info "CPU 核数 = $cores"
  if [[ "$cores" == "1" ]]; then
    warn "单核机器:WireGuard 加解密 + 软中断挤在一个核,高带宽下极易成为瓶颈。"
  fi
  # softirq 占用(瞬时采样)
  if have mpstat; then
    info "softirq 瞬时占用(mpstat):"
    mpstat -P ALL 1 1 2>/dev/null | awk '/Average|平均/{print "    "$0}' | tail -n +1 | head -6
  else
    local si; si=$(awk '/^softirq/{print $2}' /proc/stat 2>/dev/null)
    info "softirq 累计计数 = ${si:-?}(无 mpstat,装 sysstat 可看实时占比)"
  fi
  info "测速时另开窗口跑 'top' 看某个核 si% 是否打满 → 确认是否 CPU 瓶颈。"
}

# =============================================================================
# 测速:单流 vs 并发(核心判据)
# =============================================================================
_curl_speed() { curl -4 -s -o /dev/null -w '%{speed_download}' --max-time 40 "$1" 2>/dev/null || echo 0; }

speed_test() {
  title "测速:单流 vs ${PARALLEL_STREAMS} 路并发(核心判据)"
  local url="$SPEED_URL_DEFAULT"
  info "URL:$url"
  info "(走本机当前路由;在小鸡里测才反映'经隧道出口'的端到端速度)"
  hr
  echo "  跑单流…"
  local single; single=$(_curl_speed "$url")
  printf '  单流速度  : %s\n' "$(bps_human "$single")"

  echo "  跑 ${PARALLEL_STREAMS} 路并发…"
  local tmp i total=0 v; tmp=$(mktemp -d)
  for ((i=0;i<PARALLEL_STREAMS;i++)); do ( _curl_speed "$url" > "$tmp/$i" ) & done
  wait
  for ((i=0;i<PARALLEL_STREAMS;i++)); do v=$(cat "$tmp/$i" 2>/dev/null||echo 0); total=$(awk -v a="$total" -v b="$v" 'BEGIN{print a+b}'); done
  rm -rf "$tmp"
  printf '  并发总速  : %s\n' "$(bps_human "$total")"
  hr
  local ratio; ratio=$(awk -v s="$single" -v t="$total" 'BEGIN{if(s>0)printf "%.2f",t/s; else print 0}')
  info "并发/单流 = ${ratio}x"
  if awk -v r="$ratio" 'BEGIN{exit !(r>1.6)}'; then
    bad "判定:并发≫单流 → 瓶颈是【单连接窗口】(缓冲区/RTT/cubic)"
    echo "       建议 [5] 调 BBR+fq+缓冲区。"
    VERDICT="buffers"
  else
    bad "判定:并发≈单流且都不满速 → 瓶颈是【MTU / 单核CPU / 上游链路】"
    echo "       建议:看 [1] 的 MTU 是否过低、[4] 的单核 si% 是否打满;"
    echo "             MTU 偏低可走 [6] 调整;CPU 打满则需换多核或减少 string 匹配。"
    VERDICT="link_or_cpu"
  fi
}

# =============================================================================
# 调优(可回滚)
# =============================================================================
backup_once() {
  mkdir -p "$BACKUP_DIR"; local s; s="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$s"
  sysctl -a 2>/dev/null | grep -E 'net\.(core|ipv4)\.' > "$s/sysctl.snapshot" || true
  [[ -f "$SYSCTL_DROPIN" ]] && cp "$SYSCTL_DROPIN" "$s/" || true
  echo "$s" > "$BACKUP_DIR/latest"; info "已备份到 $s"
}

apply_buffers() {
  title "调优:BBR + fq + 内核缓冲区"
  cat <<EOF
  将写入 $SYSCTL_DROPIN:
    net.core.rmem_max = 16777216
    net.core.wmem_max = 16777216
    net.ipv4.tcp_rmem = 4096 87380 16777216
    net.ipv4.tcp_wmem = 4096 65536 16777216
    net.core.netdev_max_backlog = 16384
    net.core.default_qdisc = fq
    net.ipv4.tcp_congestion_control = bbr   (内核支持时)
  纯转发本身不占本机 TCP socket,但 BBR/fq 改善转发排队,缓冲区利好 backend 落地服务。
  可随时从菜单 [9] 回滚。
EOF
  confirm "确认写入并生效?" || { info "已取消"; return; }
  backup_once
  local cc=""
  if modprobe tcp_bbr 2>/dev/null && grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    cc="net.ipv4.tcp_congestion_control = bbr"
  else
    warn "内核不支持 bbr,跳过拥塞控制。"
  fi
  cat > "$SYSCTL_DROPIN" <<EOF
# Written by wg-tune.sh — delete to revert
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 16384
net.core.default_qdisc = fq
$cc
EOF
  sysctl --system >/dev/null 2>&1 && ok "已生效。重新跑 [3] 对比测速。" || bad "sysctl 应用失败"
}

adjust_mtu() {
  title "调整 WireGuard 接口 MTU(临时,立即生效)"
  detect_wg_iface
  [[ -z "$WG_IF" ]] && { bad "没有活跃 wg 接口"; return; }
  info "当前 $WG_IF MTU = $(cat "/sys/class/net/$WG_IF/mtu" 2>/dev/null)"
  cat <<EOF
  说明:干净 1500 链路上 WG 最优 MTU≈1420。你的 setup 脚本默认偏低(1060/1180)。
  这里只临时改运行中的接口做 A/B 测速,${C_BLD}不会写回 .conf${C_RESET};
  确认有效后,请到 setup-wg-*.sh 里把 WG_MTU 改成同值再重装才能持久化。
EOF
  local new; read -r -p "  新 MTU [建议 1420,直接回车取消]: " new
  [[ -z "$new" ]] && { info "已取消"; return; }
  if ! [[ "$new" =~ ^[0-9]+$ ]] || (( new < 1280 || new > 1500 )); then
    bad "MTU 非法(1280-1500)"; return
  fi
  if ip link set dev "$WG_IF" mtu "$new"; then
    ok "已把 $WG_IF MTU 临时设为 $new。跑 [3] 测速对比;无效就改回。"
    warn "注意:这是临时值,重启或 wg-quick 重连后恢复脚本里的 WG_MTU。"
  else
    bad "设置失败。"
  fi
}

rollback() {
  title "回滚 wg-tune 的改动"
  local done=0
  if [[ -f "$SYSCTL_DROPIN" ]]; then
    if confirm "删除 $SYSCTL_DROPIN 并重载?"; then
      rm -f "$SYSCTL_DROPIN"; sysctl --system >/dev/null 2>&1 || true
      ok "已删除缓冲区/BBR drop-in。"; done=1
    fi
  else
    info "无缓冲区 drop-in。"
  fi
  info "MTU 临时改动重启即恢复,无需回滚。"
  (( done )) || info "没有需要回滚的持久化改动。"
}

run_all_diag() { diag_wg; diag_buffers; diag_forward; diag_cpu; echo; info "诊断完成。量化瓶颈请跑 [3] 测速。"; }

# =============================================================================
menu() {
  while true; do
    cat <<MENU

${C_BLD}${C_CYN}wg-tune${C_RESET} — WireGuard 隧道自测/自调优 (接口默认 ${WG_NAME})
  ${C_BLD}1${C_RESET}) WG 接口诊断(内核态/用户态、MTU、handshake、传输量)
  ${C_BLD}2${C_RESET}) 缓冲区 / BBR / qdisc 体检
  ${C_BLD}3${C_RESET}) 测速:单流 vs 并发(核心判据,跑流量)
  ${C_BLD}4${C_RESET}) CPU / softirq 瓶颈检查
  ${C_BLD}5${C_RESET}) 调优:BBR + fq + 缓冲区        ${C_DIM}(写,可回滚)${C_RESET}
  ${C_BLD}6${C_RESET}) 调优:临时调 WG 接口 MTU(A/B)  ${C_DIM}(写,重启恢复)${C_RESET}
  ${C_BLD}7${C_RESET}) 全量诊断(1+2+3转发+4)
  ${C_BLD}8${C_RESET}) 一键自动:全量诊断→测速→按判据建议
  ${C_BLD}9${C_RESET}) 回滚 wg-tune 的改动
  ${C_BLD}q${C_RESET}) 退出
MENU
    if ! read -r -p "选择: " choice; then echo; warn "输入结束(EOF),退出。"; exit 0; fi
    case "$choice" in
      1) diag_wg ;;
      2) diag_buffers ;;
      3) speed_test ;;
      4) diag_cpu ;;
      5) apply_buffers ;;
      6) diag_wg; adjust_mtu ;;
      7) run_all_diag ;;
      8)
        run_all_diag; speed_test; echo
        case "${VERDICT:-}" in
          buffers) warn "建议执行 [5]。"; confirm "现在执行 [5]?" && apply_buffers ;;
          link_or_cpu) warn "建议先看 MTU/CPU;若 MTU 偏低可执行 [6] A/B。"; confirm "现在执行 [6]?" && { diag_wg; adjust_mtu; } ;;
          *) info "判据不明确,人工看上面输出。" ;;
        esac ;;
      9) rollback ;;
      q|Q) echo "再见。"; exit 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}

# =============================================================================
main() {
  need_root
  if [[ ! -t 0 ]]; then
    if [[ -e /dev/tty ]]; then exec < /dev/tty
    else
      echo "非交互输入(管道运行)且无终端。请先下载再运行:" >&2
      echo "  curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/wg-tune.sh -o wg-tune.sh" >&2
      echo "  sudo bash wg-tune.sh" >&2
      exit 1
    fi
  fi
  echo "${C_BLD}wg-tune.sh${C_RESET} — 诊断默认只读,调优需确认且可回滚。"
  echo "配套:setup-wg-gateway.sh / setup-wg-backend.sh / setup-home-vps.sh"
  have wg || warn "未检测到 wg 命令,可能此机未装 WireGuard。"
  menu
}
main "$@"
