#!/usr/bin/env bash
# 家宽出口入口白名单：只允许普通机器 IP 访问指定家宽入口端口，其他来源直接 DROP。
set -euo pipefail
trap 'echo "[ERROR] line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

STATE_DIR="/etc/home-firewall-whitelist"
CONFIG_FILE="$STATE_DIR/config.env"
APPLY_BIN="/usr/local/sbin/home-firewall-whitelist-apply"
REMOVE_BIN="/usr/local/sbin/home-firewall-whitelist-remove"
HELPER_BIN="/usr/local/bin/home-fw"
UNIT_FILE="/etc/systemd/system/home-firewall-whitelist.service"
CHAIN="HOME-WHITELIST"

DEFAULT_PORTS="${DEFAULT_PORTS:-51820/udp,6013/tcp,6013/udp}"
ALLOW_IPS="${ALLOW_IPS:-}"
PROTECT_PORTS="${PROTECT_PORTS:-}"
LOCKDOWN_ALL="${LOCKDOWN_ALL:-0}"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "请使用 root 权限运行: sudo bash $0"
    exit 1
  fi
}

valid_ip_or_cidr() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]
}

valid_port_spec() {
  local item="$1" port proto
  port="${item%/*}"
  proto="${item#*/}"
  [[ "$port" =~ ^[0-9]+(:[0-9]+)?$ ]] || return 1
  [[ "$proto" == "tcp" || "$proto" == "udp" ]] || return 1
}

install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables iproute2 ca-certificates >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache iptables iproute2 ca-certificates >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y iptables iproute ca-certificates >/dev/null 2>&1 || true
  fi
}

normalize_csv() {
  printf '%s' "$1" | sed 's/[;[:space:]]/,/g;s/，/,/g;s/,,*/,/g;s/^,*//;s/,*$//'
}

prompt_config() {
  if [[ -z "$ALLOW_IPS" ]]; then
    read -r -p "普通机器公网 IPv4 白名单，多个用逗号分隔: " ALLOW_IPS
  fi
  ALLOW_IPS="$(normalize_csv "$ALLOW_IPS")"
  [[ -n "$ALLOW_IPS" ]] || { echo "白名单不能为空"; exit 1; }
  IFS=',' read -r -a allow_arr <<< "$ALLOW_IPS"
  for ip in "${allow_arr[@]}"; do
    valid_ip_or_cidr "$ip" || { echo "IP/CIDR 格式无效: $ip"; exit 1; }
  done

  if [[ -z "$PROTECT_PORTS" ]]; then
    read -r -p "要保护的入口端口 proto，多个逗号分隔 [${DEFAULT_PORTS}]: " PROTECT_PORTS
    PROTECT_PORTS="${PROTECT_PORTS:-$DEFAULT_PORTS}"
  fi
  if [[ -z "${LOCKDOWN_ALL:-}" ]]; then
    LOCKDOWN_ALL=0
  fi
  PROTECT_PORTS="$(normalize_csv "$PROTECT_PORTS")"
  [[ -n "$PROTECT_PORTS" ]] || { echo "保护端口不能为空"; exit 1; }
  IFS=',' read -r -a port_arr <<< "$PROTECT_PORTS"
  for item in "${port_arr[@]}"; do
    valid_port_spec "$item" || { echo "端口格式无效: $item，应为 51820/udp 或 20000:30000/tcp"; exit 1; }
  done
}

write_config() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  cat > "$CONFIG_FILE" <<EOF
ALLOW_IPS=${ALLOW_IPS}
PROTECT_PORTS=${PROTECT_PORTS}
LOCKDOWN_ALL=${LOCKDOWN_ALL}
CHAIN=${CHAIN}
EOF
}

write_apply() {
  cat > "$APPLY_BIN" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
source /etc/home-firewall-whitelist/config.env

ipt() { iptables "$@"; }

ipt -N "$CHAIN" 2>/dev/null || true
ipt -F "$CHAIN"
ipt -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ipt -A "$CHAIN" -i lo -j ACCEPT

IFS=',' read -r -a allow_arr <<< "$ALLOW_IPS"
for ip in "${allow_arr[@]}"; do
  [[ -n "$ip" ]] || continue
  ipt -A "$CHAIN" -s "$ip" -j ACCEPT
done
ipt -A "$CHAIN" -j DROP

if [[ "${LOCKDOWN_ALL:-0}" == "1" ]]; then
  while ipt -D INPUT -j "$CHAIN" 2>/dev/null; do :; done
  ipt -I INPUT 1 -j "$CHAIN"
  exit 0
fi

IFS=',' read -r -a port_arr <<< "$PROTECT_PORTS"
for item in "${port_arr[@]}"; do
  [[ -n "$item" ]] || continue
  port="${item%/*}"
  proto="${item#*/}"
  while ipt -D INPUT -p "$proto" --dport "$port" -j "$CHAIN" 2>/dev/null; do :; done
  ipt -I INPUT 1 -p "$proto" --dport "$port" -j "$CHAIN"
done
SCRIPT
  chmod +x "$APPLY_BIN"
}

write_remove() {
  cat > "$REMOVE_BIN" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
source /etc/home-firewall-whitelist/config.env 2>/dev/null || exit 0
if [[ "${LOCKDOWN_ALL:-0}" == "1" ]]; then
  while iptables -D INPUT -j "${CHAIN:-HOME-WHITELIST}" 2>/dev/null; do :; done
fi
IFS=',' read -r -a port_arr <<< "${PROTECT_PORTS:-}"
for item in "${port_arr[@]}"; do
  [[ -n "$item" ]] || continue
  port="${item%/*}"
  proto="${item#*/}"
  while iptables -D INPUT -p "$proto" --dport "$port" -j "${CHAIN:-HOME-WHITELIST}" 2>/dev/null; do :; done
done
iptables -F "${CHAIN:-HOME-WHITELIST}" 2>/dev/null || true
iptables -X "${CHAIN:-HOME-WHITELIST}" 2>/dev/null || true
SCRIPT
  chmod +x "$REMOVE_BIN"
}

write_helper() {
  cat > "$HELPER_BIN" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="/etc/home-firewall-whitelist/config.env"
case "${1:-status}" in
  status)
    cat "$CONFIG_FILE" 2>/dev/null || true
    iptables -S INPUT | grep HOME-WHITELIST || true
    iptables -S HOME-WHITELIST 2>/dev/null || true
    systemctl status home-firewall-whitelist.service --no-pager --lines=8 2>/dev/null || true
    ;;
  apply|restart|on)
    systemctl enable --now home-firewall-whitelist.service >/dev/null 2>&1 || true
    /usr/local/sbin/home-firewall-whitelist-apply
    ;;
  off|stop)
    systemctl disable --now home-firewall-whitelist.service >/dev/null 2>&1 || true
    /usr/local/sbin/home-firewall-whitelist-remove
    echo "家宽入口白名单已关闭"
    ;;
  add)
    ip="${2:-}"
    [[ -n "$ip" ]] || { echo "usage: home-fw add 1.2.3.4"; exit 2; }
    source "$CONFIG_FILE"
    if [[ ",$ALLOW_IPS," != *",$ip,"* ]]; then
      sed -i "s|^ALLOW_IPS=.*|ALLOW_IPS=${ALLOW_IPS},${ip}|" "$CONFIG_FILE"
    fi
    /usr/local/sbin/home-firewall-whitelist-apply
    ;;
  remove)
    ip="${2:-}"
    [[ -n "$ip" ]] || { echo "usage: home-fw remove 1.2.3.4"; exit 2; }
    source "$CONFIG_FILE"
    new="$(printf '%s' "$ALLOW_IPS" | tr ',' '\n' | grep -v -F "$ip" | paste -sd, -)"
    sed -i "s|^ALLOW_IPS=.*|ALLOW_IPS=${new}|" "$CONFIG_FILE"
    /usr/local/sbin/home-firewall-whitelist-apply
    ;;
  *)
    echo "usage: home-fw status|apply|restart|off|add IP|remove IP" >&2
    exit 2
    ;;
esac
SCRIPT
  chmod +x "$HELPER_BIN"
}

write_service() {
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Home egress source IP whitelist firewall
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${APPLY_BIN}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
}

install_mode() {
  need_root
  install_deps
  prompt_config
  write_config
  write_apply
  write_remove
  write_helper
  write_service
  systemctl enable --now home-firewall-whitelist.service >/dev/null 2>&1 || true
  "$APPLY_BIN"
  echo
  echo "家宽入口白名单已启用"
  echo "白名单: $ALLOW_IPS"
  echo "保护端口: $PROTECT_PORTS"
  echo "全入口锁定: $LOCKDOWN_ALL"
  echo
  echo "管理命令:"
  echo "  home-fw status"
  echo "  home-fw add 普通机器IP"
  echo "  home-fw remove 普通机器IP"
  echo "  home-fw off"
}

case "${1:-install}" in
  install|"") install_mode ;;
  status) "$HELPER_BIN" status ;;
  apply|restart|on) "$HELPER_BIN" apply ;;
  off|stop) "$HELPER_BIN" off ;;
  add) "$HELPER_BIN" add "${2:-}" ;;
  remove) "$HELPER_BIN" remove "${2:-}" ;;
  *) echo "usage: $0 install|status|apply|off|add IP|remove IP" >&2; exit 2 ;;
esac
