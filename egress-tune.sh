#!/usr/bin/env bash
# =============================================================================
# egress-tune.sh — 交互式自测试 / 自分析 / 自调优 (for setup-egress-socks.sh)
# =============================================================================
#
# 目标:诊断 "SOCKS5 出口只能跑到上游速度 1/2 ~ 2/3" 的问题,定位瓶颈到
#       具体某一层,并在你确认后做最小化、可回滚的调优。
#
# 设计原则:
#   • 默认只读。所有"写"操作都需要你手动选菜单 + 二次确认。
#   • 每次写内核参数/nft 前自动备份,菜单里随时可一键回滚。
#   • 不修改 setup-egress-socks.sh,不碰它的 sing-box 配置和 systemd 单元。
#   • 单流 vs 多流并发对比是核心判据:
#       - 并发总速 >> 单流  → 瓶颈是单连接窗口 (rmem/wmem/RTT) → 调缓冲区
#       - 单流 ≈ 并发且都低  → 瓶颈是 MTU/MSS 或上游链路 → 夹 MSS / 查上游
#
# 用法:  sudo bash egress-tune.sh
#
# =============================================================================
set -uo pipefail

# ---- 常量(与 setup-egress-socks.sh 对齐)-----------------------------------
STATE_DIR="/etc/egress-socks"
CONFIG_FILE="/etc/sing-box/config.json"
INCUS_BRIDGE="${INCUS_BRIDGE:-incusbr0}"
INCUS_SUBNET="${INCUS_SUBNET:-10.10.0.0/22}"
TUN_NAME="egress-tun0"

BACKUP_DIR="/var/backups/egress-tune"
SYSCTL_DROPIN="/etc/sysctl.d/98-egress-tune.conf"
MSS_NFT_TABLE="inet egress-tune-mss"
MSS_NFT_FILE="$STATE_DIR/egress-tune-mss.nft"

# 测速目标(可换):大文件 + speedtest 风格端点
SPEED_URL_DEFAULT="https://hil.proof.ovh.us/files/1Gb.dat"   # OVH 1Gb 测试文件(由 --max-time 限时,不会下满)
PARALLEL_STREAMS=4

C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
C_YEL=$'\033[33m'; C_CYN=$'\033[36m'; C_BLD=$'\033[1m'

# ---- 工具函数 ---------------------------------------------------------------
need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请用 root 运行:sudo bash $0" >&2
    exit 1
  fi
}

hr()   { printf '%s\n' "------------------------------------------------------------"; }
ok()   { printf '  %s[OK]%s   %s\n'   "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '  %s[!!]%s   %s\n'   "$C_YEL" "$C_RESET" "$*"; }
bad()  { printf '  %s[XX]%s   %s\n'   "$C_RED" "$C_RESET" "$*"; }
info() { printf '  %s·%s    %s\n'     "$C_DIM" "$C_RESET" "$*"; }
title(){ printf '\n%s== %s ==%s\n'    "$C_BLD$C_CYN" "$*" "$C_RESET"; }

confirm() {
  local prompt="${1:-确认执行?} [y/N] " ans
  read -r -p "$prompt" ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

have() { command -v "$1" >/dev/null 2>&1; }

# 从 sing-box 配置里抽出上游 SOCKS server / port
read_upstream() {
  UP_HOST=""; UP_PORT=""
  [[ -s "$CONFIG_FILE" ]] || return 0
  have python3 || return 0
  read -r UP_HOST UP_PORT < <(python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null
import json,sys
try:
    cfg=json.load(open(sys.argv[1]))
    for o in cfg.get("outbounds",[]):
        if o.get("type")=="socks":
            print(o.get("server",""), o.get("server_port","")); break
except Exception:
    pass
PY
) || true
}

# 取本机 main 表默认路由的网关 + 出口网卡
read_default_route() {
  DEF_DEV=""; DEF_GW=""
  read -r DEF_DEV DEF_GW < <(ip -4 route show default 2>/dev/null \
    | awk '/default/{for(i=1;i<=NF;i++){if($i=="dev")dev=$(i+1);if($i=="via")gw=$(i+1)}}END{print dev, gw}')
}

# 找一个 RUNNING 的小鸡名
first_guest() {
  have incus || { echo ""; return; }
  incus list -c n,s --format csv 2>/dev/null | awk -F, '$2=="RUNNING"{print $1; exit}'
}

bps_human() {
  # 入参 bytes/sec
  local b="${1:-0}"
  awk -v b="$b" 'BEGIN{
    mbit=b*8/1000000;
    printf "%.1f Mbit/s (%.2f MB/s)", mbit, b/1048576
  }'
}

# =============================================================================
# 诊断:内核缓冲区
# =============================================================================
diag_buffers() {
  title "内核 TCP 缓冲区上限"
  local rmax wmax trmem twmem qdisc cc
  rmax=$(sysctl -n net.core.rmem_max 2>/dev/null)
  wmax=$(sysctl -n net.core.wmem_max 2>/dev/null)
  trmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)
  twmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)

  info "rmem_max = ${rmax:-?}    wmem_max = ${wmax:-?}"
  info "tcp_rmem = ${trmem:-?}"
  info "tcp_wmem = ${twmem:-?}"
  info "qdisc = ${qdisc:-?}    congestion = ${cc:-?}"

  BUF_TOO_SMALL=0
  if [[ -n "$rmax" && "$rmax" -lt 8388608 ]]; then
    bad "rmem_max 仅 ${rmax}B (<8MB)。高 RTT 单条 TCP 会被窗口卡死,这通常就是'只能跑一半'的主因。"
    BUF_TOO_SMALL=1
  else
    ok "rmem_max 足够 (${rmax}B)"
  fi
  if [[ "$cc" != "bbr" ]]; then
    warn "拥塞控制不是 bbr (当前 ${cc:-?})。BBR 在有丢包的跨境线上明显更稳。"
  else
    ok "拥塞控制 = bbr"
  fi
}

# =============================================================================
# 诊断:RTT 与单流理论上限
# =============================================================================
diag_rtt() {
  title "到上游 SOCKS 的 RTT 与单流理论上限"
  read_upstream
  if [[ -z "$UP_HOST" ]]; then
    warn "无法从 $CONFIG_FILE 读到上游 SOCKS server,跳过。"
    return
  fi
  info "上游 SOCKS:$UP_HOST:${UP_PORT:-?}"
  local rtt
  rtt=$(ping -c5 -W2 "$UP_HOST" 2>/dev/null | awk -F'/' 'END{print $5}')
  if [[ -z "$rtt" ]]; then
    warn "ping 不通(可能禁 ICMP),无法测 RTT。改用 TCP 连通性。"
    if have nc; then
      nc -z -w5 "$UP_HOST" "${UP_PORT:-1080}" 2>/dev/null \
        && ok "TCP 可达 $UP_HOST:${UP_PORT}" || bad "TCP 不可达 $UP_HOST:${UP_PORT}"
    fi
    return
  fi
  info "平均 RTT = ${rtt} ms"
  # 单流上限 ≈ rmem_max(窗口) / RTT
  local rmax; rmax=$(sysctl -n net.core.rmem_max 2>/dev/null)
  [[ -n "$rmax" && -n "$rtt" ]] && awk -v w="$rmax" -v r="$rtt" 'BEGIN{
    if(r>0){ mbit=(w*8)/(r/1000)/1000000;
      printf "  %s·%s    当前缓冲区下单条 TCP 理论上限 ≈ %.0f Mbit/s\n","\033[2m","\033[0m", mbit }
  }'
  RTT_MS="$rtt"
}

# =============================================================================
# 诊断:MTU / MSS
# =============================================================================
diag_mtu() {
  title "MTU / MSS 链路检查"
  local tun_mtu br_mtu
  tun_mtu=$(cat "/sys/class/net/$TUN_NAME/mtu" 2>/dev/null || echo "?")
  br_mtu=$(cat "/sys/class/net/$INCUS_BRIDGE/mtu" 2>/dev/null || echo "?")
  info "TUN($TUN_NAME) MTU = $tun_mtu    桥($INCUS_BRIDGE) MTU = $br_mtu"

  MSS_PRESENT=0
  if nft list ruleset 2>/dev/null | grep -qi 'tcp option maxseg'; then
    ok "检测到 nft MSS clamp 规则"
    MSS_PRESENT=1
  elif iptables-save 2>/dev/null | grep -qi 'TCPMSS'; then
    ok "检测到 iptables TCPMSS clamp 规则"
    MSS_PRESENT=1
  else
    warn "没有任何 MSS clamp。若上游 underlay < 1500(PPPoE/隧道很常见),会触发 PMTUD 黑洞→重传→掉速。"
  fi

  # PMTU 探测:对上游做几次不分片大包,找黑洞
  read_upstream
  if [[ -n "$UP_HOST" ]] && have ping; then
    local sz ok_sz=0
    for sz in 1472 1400 1360 1300 1200; do
      if ping -c1 -W2 -M do -s "$sz" "$UP_HOST" >/dev/null 2>&1; then
        ok_sz="$sz"; break
      fi
    done
    if [[ "$ok_sz" -gt 0 ]]; then
      info "到上游不分片可通过的最大 payload ≈ ${ok_sz}B (即 PMTU ≈ $((ok_sz+28)))"
      if [[ "$ok_sz" -lt 1472 ]]; then
        warn "路径 MTU < 1500。建议把小鸡转发链 MSS 夹到 $((ok_sz-40)) 左右。"
        SUGGEST_MSS=$((ok_sz-40))
      fi
    else
      warn "1200B 不分片都不通,可能全程禁 ICMP(PMTUD 必黑洞)。强烈建议手动夹 MSS=1360。"
      SUGGEST_MSS=1360
    fi
  fi
}

# =============================================================================
# 诊断:转发/NAT 卸载相关
# =============================================================================
diag_offload() {
  title "网卡 offload / forwarding"
  read_default_route
  info "默认出口网卡 = ${DEF_DEV:-?}  网关 = ${DEF_GW:-?}"
  local fwd; fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
  [[ "$fwd" == "1" ]] && ok "ip_forward = 1" || warn "ip_forward = ${fwd:-0}"
  if [[ -n "${DEF_DEV:-}" ]] && have ethtool; then
    local gro gso tso
    gro=$(ethtool -k "$DEF_DEV" 2>/dev/null | awk '/generic-receive-offload/{print $2}')
    info "出口网卡 GRO=${gro:-?} (转发场景 GRO 偶尔影响延迟,一般无需动)"
  fi
}

# =============================================================================
# 测速:单流 vs 多流并发(核心判据)
# =============================================================================
_curl_speed() {
  # $1 url ; 输出 bytes/sec(平均)
  curl -4 -s -o /dev/null -w '%{speed_download}' --max-time 40 "$1" 2>/dev/null || echo 0
}

speed_test() {
  title "测速:单流 vs ${PARALLEL_STREAMS} 路并发(核心判据)"
  local url="${SPEED_URL:-$SPEED_URL_DEFAULT}"
  info "测试 URL:$url"
  info "(走当前默认路由,即经过 sing-box TUN → SOCKS 出口)"
  hr

  echo "  正在跑单流..."
  local single; single=$(_curl_speed "$url")
  printf '  单流速度      : %s\n' "$(bps_human "$single")"

  echo "  正在跑 ${PARALLEL_STREAMS} 路并发..."
  local tmp; tmp=$(mktemp -d)
  local i
  for ((i=0; i<PARALLEL_STREAMS; i++)); do
    ( _curl_speed "$url" > "$tmp/$i" ) &
  done
  wait
  local total=0 v
  for ((i=0; i<PARALLEL_STREAMS; i++)); do
    v=$(cat "$tmp/$i" 2>/dev/null || echo 0)
    total=$(awk -v a="$total" -v b="$v" 'BEGIN{print a+b}')
  done
  rm -rf "$tmp"
  printf '  并发总速      : %s\n' "$(bps_human "$total")"
  hr

  # 判据
  local ratio
  ratio=$(awk -v s="$single" -v t="$total" 'BEGIN{ if(s>0) printf "%.2f", t/s; else print "0" }')
  info "并发/单流 倍率 = ${ratio}x"
  if awk -v r="$ratio" 'BEGIN{exit !(r>1.6)}'; then
    echo
    bad   "判定:并发明显快于单流 → 瓶颈是【单连接窗口】"
    echo  "       根因多半是 rmem_max/wmem_max 太小 或 RTT 偏高。"
    echo  "       建议:菜单 [4] 调大内核缓冲区(BBR+fq+16MB)。"
    VERDICT="buffers"
  else
    echo
    bad   "判定:并发≈单流且都不满速 → 瓶颈是【链路/MTU/上游】"
    echo  "       根因多半是 MSS 未钳制(PMTUD 黑洞) 或 上游 SOCKS 线本身慢。"
    echo  "       建议:菜单 [5] 钳制小鸡 MSS;若仍慢则是上游线路,换 SOCKS 出口。"
    VERDICT="mtu_or_upstream"
  fi
}

# =============================================================================
# 调优动作(全部可回滚)
# =============================================================================
backup_once() {
  mkdir -p "$BACKUP_DIR"
  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  CUR_BACKUP="$BACKUP_DIR/$stamp"
  mkdir -p "$CUR_BACKUP"
  sysctl -a 2>/dev/null | grep -E 'net\.(core|ipv4)\.' > "$CUR_BACKUP/sysctl.snapshot" || true
  nft list ruleset > "$CUR_BACKUP/nft.ruleset" 2>/dev/null || true
  [[ -f "$SYSCTL_DROPIN" ]] && cp "$SYSCTL_DROPIN" "$CUR_BACKUP/" || true
  echo "$CUR_BACKUP" > "$BACKUP_DIR/latest"
  info "已备份当前状态到 $CUR_BACKUP"
}

apply_buffers() {
  title "调优:内核 TCP 缓冲区 + BBR + fq"
  cat <<EOF
  将写入 $SYSCTL_DROPIN:
    net.core.rmem_max = 16777216
    net.core.wmem_max = 16777216
    net.ipv4.tcp_rmem = 4096 87380 16777216
    net.ipv4.tcp_wmem = 4096 65536 16777216
    net.core.default_qdisc = fq
    net.ipv4.tcp_congestion_control = bbr   (若内核支持)
  这些是上限/自动调优,不会预占内存;可随时从菜单 [9] 回滚。
EOF
  confirm "确认写入并立即生效?" || { info "已取消。"; return; }
  backup_once
  local cc_line=""
  if modprobe tcp_bbr 2>/dev/null && grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    cc_line="net.ipv4.tcp_congestion_control = bbr"
  else
    warn "内核不支持 bbr,跳过拥塞控制设置。"
  fi
  cat > "$SYSCTL_DROPIN" <<EOF
# Written by egress-tune.sh — safe to delete to revert
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.default_qdisc = fq
$cc_line
EOF
  if sysctl --system >/dev/null 2>&1; then
    ok "已生效。建议重新跑 [3] 测速对比。"
  else
    bad "sysctl 应用失败,请检查 $SYSCTL_DROPIN"
  fi
}

apply_mss() {
  title "调优:小鸡转发链 TCP MSS clamp"
  local mss="${SUGGEST_MSS:-1360}"
  read -r -p "  要钳制的 MSS 值 [默认 $mss]: " in
  [[ -n "$in" ]] && mss="$in"
  if ! [[ "$mss" =~ ^[0-9]+$ ]] || (( mss < 500 || mss > 1460 )); then
    bad "MSS 非法(应 500-1460)。"; return
  fi
  cat <<EOF
  将创建独立 nft 表 ${MSS_NFT_TABLE}:
    对经过 $INCUS_BRIDGE 转发的 TCP SYN 钳制 MSS = $mss
  仅影响小鸡 forward 流量,不碰 setup-egress-socks.sh 的 egress-bypass 表。
  可随时从菜单 [9] 回滚。
EOF
  confirm "确认应用?" || { info "已取消。"; return; }
  backup_once
  mkdir -p "$STATE_DIR"
  cat > "$MSS_NFT_FILE" <<NFT
table ${MSS_NFT_TABLE} {
  chain forward {
    type filter hook forward priority mangle; policy accept;
    iifname "${INCUS_BRIDGE}" tcp flags syn tcp option maxseg size set ${mss}
    oifname "${INCUS_BRIDGE}" tcp flags syn tcp option maxseg size set ${mss}
  }
}
NFT
  nft delete table ${MSS_NFT_TABLE} 2>/dev/null || true
  if nft -f "$MSS_NFT_FILE"; then
    ok "MSS clamp = $mss 已应用。"
    warn "注意:这是临时规则,重启后失效。要持久化我可以帮你加一个 systemd 单元(再说一声)。"
  else
    bad "nft 应用失败。"
  fi
}

rollback() {
  title "回滚 egress-tune 的改动"
  local restored=0
  if [[ -f "$SYSCTL_DROPIN" ]]; then
    if confirm "删除 $SYSCTL_DROPIN 并恢复默认 sysctl?"; then
      rm -f "$SYSCTL_DROPIN"
      sysctl --system >/dev/null 2>&1 || true
      ok "已删除缓冲区 drop-in 并重载。"
      restored=1
    fi
  else
    info "无缓冲区 drop-in。"
  fi
  if nft list table ${MSS_NFT_TABLE} >/dev/null 2>&1; then
    if confirm "删除 MSS clamp 表 ${MSS_NFT_TABLE}?"; then
      nft delete table ${MSS_NFT_TABLE} 2>/dev/null || true
      rm -f "$MSS_NFT_FILE"
      ok "已删除 MSS clamp。"
      restored=1
    fi
  else
    info "无 MSS clamp 表。"
  fi
  (( restored )) && warn "如改动了运行参数,部分需重启 sing-box 或重连才完全恢复。" \
                 || info "没有需要回滚的 egress-tune 改动。"
}

run_all_diag() {
  diag_buffers
  diag_rtt
  diag_mtu
  diag_offload
  echo
  info "诊断完成。若要量化瓶颈,跑菜单 [3] 测速。"
}

# =============================================================================
# 菜单
# =============================================================================
menu() {
  while true; do
    cat <<MENU

${C_BLD}${C_CYN}egress-tune${C_RESET} — SOCKS5 出口自测/自调优
  ${C_BLD}1${C_RESET}) 全量诊断(只读:缓冲区/RTT/MTU/MSS/转发)
  ${C_BLD}2${C_RESET}) 仅快速体检(缓冲区 + RTT 上限)
  ${C_BLD}3${C_RESET}) 测速:单流 vs 并发(核心判据,会跑流量)
  ${C_BLD}4${C_RESET}) 调优:内核缓冲区 + BBR + fq    ${C_DIM}(写,可回滚)${C_RESET}
  ${C_BLD}5${C_RESET}) 调优:小鸡转发链 MSS clamp     ${C_DIM}(写,可回滚)${C_RESET}
  ${C_BLD}6${C_RESET}) 一键自动:诊断→测速→按判据给出建议
  ${C_BLD}9${C_RESET}) 回滚 egress-tune 的所有改动
  ${C_BLD}q${C_RESET}) 退出
MENU
    if ! read -r -p "选择: " choice; then
      echo; warn "输入结束(EOF),退出。"; exit 0
    fi
    case "$choice" in
      1) run_all_diag ;;
      2) diag_buffers; diag_rtt ;;
      3) speed_test ;;
      4) apply_buffers ;;
      5) diag_mtu; apply_mss ;;
      6)
        run_all_diag
        speed_test
        echo
        case "${VERDICT:-}" in
          buffers)
            warn "自动建议:执行 [4] 调大缓冲区。"
            confirm "现在就执行 [4]?" && apply_buffers ;;
          mtu_or_upstream)
            warn "自动建议:执行 [5] 钳制 MSS;若无改善则为上游线路问题。"
            confirm "现在就执行 [5]?" && { diag_mtu; apply_mss; } ;;
          *) info "判据不明确,请人工看上面输出。" ;;
        esac
        ;;
      9) rollback ;;
      q|Q) echo "再见。"; exit 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}

# =============================================================================
main() {
  need_root
  # 通过 `curl ... | sudo bash` 管道运行时,stdin 是脚本内容而非键盘,
  # 会导致 read 立即读到空值、菜单死循环。这里把交互输入接回控制终端。
  if [[ ! -t 0 ]]; then
    if [[ -e /dev/tty ]]; then
      exec < /dev/tty
    else
      echo "检测到非交互输入(可能是管道运行),且无可用终端。" >&2
      echo "请改为先下载再运行:" >&2
      echo "  curl -fsSL https://raw.githubusercontent.com/JetSprow/23232/main/egress-tune.sh -o egress-tune.sh" >&2
      echo "  sudo bash egress-tune.sh" >&2
      exit 1
    fi
  fi
  echo "${C_BLD}egress-tune.sh${C_RESET}  —  诊断默认只读,调优需确认且可回滚。"
  echo "目标脚本:setup-egress-socks.sh  |  上游配置:$CONFIG_FILE"
  if [[ ! -s "$CONFIG_FILE" ]]; then
    warn "未找到 $CONFIG_FILE,可能还没装 egress-socks。部分诊断会跳过。"
  fi
  menu
}

main "$@"
