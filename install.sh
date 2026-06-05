#!/usr/bin/env bash
# Interactive installer for JetSprow/23232 network scripts.
set -euo pipefail
trap 'echo "[ERROR] line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

REPO_URL="${REPO_URL:-https://github.com/JetSprow/23232.git}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/JetSprow/23232/main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/23232}"

is_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

as_root() {
  if is_root; then
    "$@"
  else
    sudo "$@"
  fi
}

need_root() {
  if ! is_root && ! command -v sudo >/dev/null 2>&1; then
    echo "需要 root 权限，且当前系统没有 sudo。请用 root 执行。"
    exit 1
  fi
}

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then
    echo apt
  elif command -v apk >/dev/null 2>&1; then
    echo apk
  elif command -v dnf >/dev/null 2>&1; then
    echo dnf
  elif command -v yum >/dev/null 2>&1; then
    echo yum
  else
    echo unknown
  fi
}

install_base_tools() {
  local pm
  pm="$(detect_pm)"
  case "$pm" in
    apt)
      as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bash curl ca-certificates git sudo
      ;;
    apk)
      as_root apk update
      as_root apk add --no-cache bash curl ca-certificates git sudo
      ;;
    dnf)
      as_root dnf install -y bash curl ca-certificates git sudo
      ;;
    yum)
      as_root yum install -y bash curl ca-certificates git sudo
      ;;
    *)
      echo "未识别包管理器，请先手动安装 bash curl ca-certificates git。"
      ;;
  esac
}

ensure_repo() {
  as_root mkdir -p "$(dirname "$INSTALL_DIR")"
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    as_root git -C "$INSTALL_DIR" pull --ff-only || true
  else
    if command -v git >/dev/null 2>&1; then
      as_root rm -rf "$INSTALL_DIR"
      as_root git clone "$REPO_URL" "$INSTALL_DIR"
    else
      as_root mkdir -p "$INSTALL_DIR"
      local f
      for f in \
        setup-home-vps.sh setup-normal-vps.sh setup-home-socks5.sh setup-home-ss.sh \
        setup-home-firewall-whitelist.sh \
        setup-egress-socks.sh setup-gre-gateway.sh setup-gre-backend.sh \
        setup-wg-gateway.sh setup-wg-backend.sh setup-ab-entry.sh setup-ab-relay.sh \
        diagnose-github-raw.sh; do
        curl -fsSL "${RAW_BASE}/${f}" | as_root tee "${INSTALL_DIR}/${f}" >/dev/null
      done
    fi
  fi
  as_root chmod +x "$INSTALL_DIR"/*.sh
}

ask() {
  local prompt="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " value
    printf '%s' "${value:-$default}"
  else
    read -r -p "${prompt}: " value
    printf '%s' "$value"
  fi
}

ask_secret() {
  local prompt="$1" value
  read -r -s -p "${prompt}: " value
  echo >&2
  printf '%s' "$value"
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

run_script() {
  local script="$1"
  shift || true
  echo
  echo "==> 执行 ${script}"
  echo
  as_root env "$@" bash "${INSTALL_DIR}/${script}"
}

pause() {
  echo
  read -r -p "按回车返回菜单..." _
}

header() {
  clear 2>/dev/null || true
  cat <<'EOF'
============================================================
  23232 网络脚本交互式安装器
============================================================
EOF
  echo "安装目录: ${INSTALL_DIR}"
  echo
}

menu() {
  cat <<'EOF'
请选择要安装/执行的内容:

  1. 家宽 WireGuard 出口端
  2. 普通 VPS -> 家宽 WireGuard 客户端
  3. 家宽 SOCKS5 服务端
  4. 家宽 Shadowsocks 服务端
  5. 普通机器接入 SOCKS5/SS 上游出口
  6. GRE 优化线路网关端
  7. GRE 优化线路普通节点端
  8. WireGuard 优化线路网关端
 9. WireGuard 优化线路普通节点端
10. 三机 AB 隧道 A 入口机
11. 三机 AB 隧道 B 中继机
 12. 家宽入口 IP 白名单防护
 13. GitHub Raw / HTTPS 卡住诊断
 14. 更新本地脚本
  0. 退出
EOF
}

install_home_wg() {
  local port mtu mss allow lockdown
  port="$(ask "WireGuard 监听端口" "51820")"
  valid_port "$port" || { echo "端口无效"; return 1; }
  mtu="$(ask "WG_MTU，留空用默认" "")"
  mss="$(ask "TCP_MSS，留空用默认" "")"
  allow="$(ask "普通机器公网 IPv4 白名单，多个用逗号分隔，留空跳过" "")"
  lockdown="$(ask "是否锁定所有入站，只允许白名单 IP 1/0；默认只保护 WireGuard 端口" "0")"
  local envs=("WG_PORT=${port}")
  [[ -n "$mtu" ]] && envs+=("WG_MTU=${mtu}")
  [[ -n "$mss" ]] && envs+=("TCP_MSS=${mss}")
  [[ -n "$allow" ]] && envs+=("ALLOW_IPS=${allow}" "LOCKDOWN_ALL=${lockdown}")
  [[ -z "$allow" ]] && envs+=("HOME_FIREWALL_SKIP=1")
  run_script setup-home-vps.sh "${envs[@]}"
}

install_normal_wg() {
  local mtu mss
  mtu="$(ask "WG_MTU，留空用默认" "")"
  mss="$(ask "TCP_MSS，留空用默认" "")"
  local envs=()
  [[ -n "$mtu" ]] && envs+=("WG_MTU=${mtu}")
  [[ -n "$mss" ]] && envs+=("TCP_MSS=${mss}")
  run_script setup-normal-vps.sh "${envs[@]}"
}

install_home_socks5() {
  local host port user pass mss allow lockdown
  host="$(ask "对外入口 IP/域名，留空自动检测" "")"
  port="$(ask "SOCKS5 监听端口" "6013")"
  valid_port "$port" || { echo "端口无效"; return 1; }
  user="$(ask "用户名，留空自动生成" "")"
  pass="$(ask_secret "密码，留空自动生成")"
  mss="$(ask "SOCKS_TCP_MSS" "1200")"
  allow="$(ask "普通机器公网 IPv4 白名单，多个用逗号分隔，留空跳过" "")"
  lockdown="$(ask "是否锁定所有入站，只允许白名单 IP 1/0；默认只保护 SOCKS5 端口" "0")"
  local envs=("SOCKS_PORT=${port}" "SOCKS_TCP_MSS=${mss}")
  [[ -n "$host" ]] && envs+=("SOCKS_HOST=${host}")
  [[ -n "$user" ]] && envs+=("SOCKS_USER=${user}")
  [[ -n "$pass" ]] && envs+=("SOCKS_PASS=${pass}")
  [[ -n "$allow" ]] && envs+=("ALLOW_IPS=${allow}" "LOCKDOWN_ALL=${lockdown}")
  [[ -z "$allow" ]] && envs+=("HOME_FIREWALL_SKIP=1")
  run_script setup-home-socks5.sh "${envs[@]}"
}

install_home_ss() {
  local host port method pass allow lockdown
  host="$(ask "对外入口 IP/域名，留空自动检测" "")"
  port="$(ask "Shadowsocks 监听端口" "6013")"
  valid_port "$port" || { echo "端口无效"; return 1; }
  method="$(ask "加密方法" "aes-256-gcm")"
  pass="$(ask_secret "密码，留空自动生成")"
  allow="$(ask "普通机器公网 IPv4 白名单，多个用逗号分隔，留空跳过" "")"
  lockdown="$(ask "是否锁定所有入站，只允许白名单 IP 1/0；默认只保护 Shadowsocks 端口" "0")"
  local envs=("SS_PORT=${port}" "SS_METHOD=${method}")
  [[ -n "$host" ]] && envs+=("SS_HOST=${host}")
  [[ -n "$pass" ]] && envs+=("SS_PASSWORD=${pass}")
  [[ -n "$allow" ]] && envs+=("ALLOW_IPS=${allow}" "LOCKDOWN_ALL=${lockdown}")
  [[ -z "$allow" ]] && envs+=("HOME_FIREWALL_SKIP=1")
  run_script setup-home-ss.sh "${envs[@]}"
}

install_egress_proxy() {
  local proxy
  proxy="$(ask "上游代理 URL (socks5://... 或 ss://...)" "")"
  if [[ -n "$proxy" ]]; then
    run_script setup-egress-socks.sh "BUILTIN_PROXY_URL=${proxy}"
  else
    run_script setup-egress-socks.sh
  fi
}

install_gre_gateway() {
  local backend subnet range enable mtu mss
  backend="$(ask "普通 Incus 节点公网 IPv4/域名" "")"
  [[ -n "$backend" ]] || { echo "普通节点地址不能为空"; return 1; }
  subnet="$(ask "小鸡/Incus bridge 网段" "10.10.0.0/22")"
  range="$(ask "预转发端口范围" "20000:30000")"
  enable="$(ask "是否开启整段预转发 1/0" "1")"
  mtu="$(ask "GRE_MTU" "1280")"
  mss="$(ask "TCP_MSS" "1240")"
  run_script setup-gre-gateway.sh \
    "BACKEND_PUBLIC_IP=${backend}" "GUEST_SUBNET=${subnet}" \
    "PREFORWARD_RANGE=${range}" "PREFORWARD_ENABLE=${enable}" \
    "GRE_MTU=${mtu}" "TCP_MSS=${mss}"
}

install_gre_backend() {
  local gateway subnet bridge range enable mtu mss
  gateway="$(ask "优化线路节点公网 IPv4/域名" "")"
  [[ -n "$gateway" ]] || { echo "优化节点地址不能为空"; return 1; }
  bridge="$(ask "Incus bridge 名称" "incusbr0")"
  subnet="$(ask "小鸡/Incus bridge 网段" "10.10.0.0/22")"
  range="$(ask "预转发端口范围" "20000:30000")"
  enable="$(ask "是否开启整段预转发 1/0" "1")"
  mtu="$(ask "GRE_MTU" "1280")"
  mss="$(ask "TCP_MSS" "1240")"
  run_script setup-gre-backend.sh \
    "GATEWAY_PUBLIC_IP=${gateway}" "INCUS_BRIDGE=${bridge}" "GUEST_SUBNET=${subnet}" \
    "PREFORWARD_RANGE=${range}" "PREFORWARD_ENABLE=${enable}" \
    "GRE_MTU=${mtu}" "TCP_MSS=${mss}"
}

install_wg_gateway() {
  local subnet port backend_key range enable mtu
  subnet="$(ask "小鸡/Incus bridge 网段" "10.10.0.0/22")"
  port="$(ask "WireGuard 监听端口" "51820")"
  valid_port "$port" || { echo "端口无效"; return 1; }
  backend_key="$(ask "普通节点 WireGuard 公钥，留空只生成网关公钥" "")"
  range="$(ask "预转发端口范围" "20000:30000")"
  enable="$(ask "是否开启整段预转发 1/0" "1")"
  mtu="$(ask "WG_MTU" "1180")"
  local envs=("GUEST_SUBNET=${subnet}" "WG_PORT=${port}" "PREFORWARD_RANGE=${range}" "PREFORWARD_ENABLE=${enable}" "WG_MTU=${mtu}")
  [[ -n "$backend_key" ]] && envs+=("BACKEND_PUBLIC_KEY=${backend_key}")
  run_script setup-wg-gateway.sh "${envs[@]}"
}

install_wg_backend() {
  local gateway port key bridge subnet range enable mtu
  gateway="$(ask "优化线路节点公网 IPv4/域名，留空只生成普通节点公钥" "")"
  port="$(ask "网关 WireGuard 端口" "51820")"
  valid_port "$port" || { echo "端口无效"; return 1; }
  key="$(ask "优化线路网关 WireGuard 公钥，留空只生成普通节点公钥" "")"
  bridge="$(ask "Incus bridge 名称" "incusbr0")"
  subnet="$(ask "小鸡/Incus bridge 网段" "10.10.0.0/22")"
  range="$(ask "预转发端口范围" "20000:30000")"
  enable="$(ask "是否开启整段预转发 1/0" "1")"
  mtu="$(ask "WG_MTU" "1180")"
  local envs=("GATEWAY_PORT=${port}" "INCUS_BRIDGE=${bridge}" "GUEST_SUBNET=${subnet}" "PREFORWARD_RANGE=${range}" "PREFORWARD_ENABLE=${enable}" "WG_MTU=${mtu}")
  [[ -n "$gateway" ]] && envs+=("GATEWAY_PUBLIC_IP=${gateway}")
  [[ -n "$key" ]] && envs+=("GATEWAY_PUBLIC_KEY=${key}")
  run_script setup-wg-backend.sh "${envs[@]}"
}

install_ab_entry() {
  local port b_key range mtu
  port="$(ask "A WireGuard 监听端口" "51821")"
  valid_port "$port" || { echo "端口无效"; return 1; }
  b_key="$(ask "B 中继机 WireGuard 公钥，留空只生成 A 公钥" "")"
  range="$(ask "用户入口端口范围" "20000:30000")"
  mtu="$(ask "WG_MTU" "1280")"
  local envs=("WG_PORT=${port}" "PREFORWARD_RANGE=${range}" "WG_MTU=${mtu}")
  [[ -n "$b_key" ]] && envs+=("B_PUBLIC_KEY=${b_key}")
  run_script setup-ab-entry.sh "${envs[@]}"
}

install_ab_relay() {
  local port a_endpoint a_key c_target range mtu
  port="$(ask "A WireGuard 监听端口" "51821")"
  valid_port "$port" || { echo "端口无效"; return 1; }
  a_endpoint="$(ask "A 入口机公网 IPv4/域名，留空只生成 B 公钥" "")"
  a_key="$(ask "A 入口机 WireGuard 公钥，留空只生成 B 公钥" "")"
  c_target="$(ask "C 小鸡所在机器公网 IPv4/域名" "")"
  range="$(ask "用户入口端口范围" "20000:30000")"
  mtu="$(ask "WG_MTU" "1280")"
  local envs=("WG_PORT=${port}" "PREFORWARD_RANGE=${range}" "WG_MTU=${mtu}")
  [[ -n "$a_endpoint" ]] && envs+=("A_ENDPOINT=${a_endpoint}")
  [[ -n "$a_key" ]] && envs+=("A_PUBLIC_KEY=${a_key}")
  [[ -n "$c_target" ]] && envs+=("C_TARGET=${c_target}")
  run_script setup-ab-relay.sh "${envs[@]}"
}

install_home_firewall_whitelist() {
  local ips ports lockdown
  ips="$(ask "普通机器公网 IPv4 白名单，多个用逗号分隔" "")"
  [[ -n "$ips" ]] || { echo "白名单不能为空"; return 1; }
  ports="$(ask "保护端口 proto，多个逗号分隔" "51820/udp,6013/tcp,6013/udp")"
  lockdown="$(ask "是否锁定所有入站，只允许白名单 IP 1/0；默认只保护上述端口" "0")"
  run_script setup-home-firewall-whitelist.sh "ALLOW_IPS=${ips}" "PROTECT_PORTS=${ports}" "LOCKDOWN_ALL=${lockdown}"
}

run_diagnose() {
  run_script diagnose-github-raw.sh
}

main() {
  need_root
  install_base_tools
  ensure_repo

  while true; do
    header
    menu
    echo
    local choice
    read -r -p "输入序号: " choice
    case "$choice" in
      1) install_home_wg; pause ;;
      2) install_normal_wg; pause ;;
      3) install_home_socks5; pause ;;
      4) install_home_ss; pause ;;
      5) install_egress_proxy; pause ;;
      6) install_gre_gateway; pause ;;
      7) install_gre_backend; pause ;;
      8) install_wg_gateway; pause ;;
      9) install_wg_backend; pause ;;
      10) install_ab_entry; pause ;;
      11) install_ab_relay; pause ;;
      12) install_home_firewall_whitelist; pause ;;
      13) run_diagnose; pause ;;
      14) ensure_repo; echo "已更新 ${INSTALL_DIR}"; pause ;;
      0) exit 0 ;;
      *) echo "无效序号"; pause ;;
    esac
  done
}

main "$@"
