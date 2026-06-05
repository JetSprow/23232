#!/usr/bin/env bash
# 家宽 VPS SOCKS5 服务端一键脚本
# 功能: 安装 dante-server，创建用户名密码，输出 socks5://用户名:密码@地址:端口
# 用法: sudo bash setup-home-socks5.sh
# 可选:
#   sudo SOCKS_PORT=6013 bash setup-home-socks5.sh
#   sudo SOCKS_HOST=home.example.com SOCKS_PORT=6013 bash setup-home-socks5.sh
#   sudo SOCKS_PORT=6013 SOCKS_USER=myuser SOCKS_PASS=mypass bash setup-home-socks5.sh
#   sudo SOCKS_TCP_MSS=1200 bash setup-home-socks5.sh
#   sudo ALLOW_IPS=普通机器公网IP bash setup-home-socks5.sh
set -euo pipefail
trap 'echo "[ERROR] 脚本在第 ${LINENO} 行退出: ${BASH_COMMAND}" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "需要 root 权限 (sudo)"; exit 1; }
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/JetSprow/23232/main}"
HOME_ALLOW_IPS="${HOME_ALLOW_IPS:-${ALLOW_IPS:-}}"
HOME_FIREWALL_LOCKDOWN="${HOME_FIREWALL_LOCKDOWN:-${LOCKDOWN_ALL:-0}}"
HOME_FIREWALL_SKIP="${HOME_FIREWALL_SKIP:-0}"

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

valid_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]
}

gen_hex() {
  openssl rand -hex "$1"
}

setup_home_firewall_whitelist() {
  local ports="$1" script_path tmp_script
  if [[ "$HOME_FIREWALL_SKIP" == "1" ]]; then
    echo "    [!] 已选择跳过家宽入口白名单防护。"
    return 0
  fi
  if [[ -z "$HOME_ALLOW_IPS" && -t 0 ]]; then
    echo
    echo "建议开启家宽入口 IP 白名单，只允许普通机器访问 SOCKS5 入口。"
    read -rp "普通机器公网 IPv4 白名单，多个用逗号分隔 [留空跳过]: " HOME_ALLOW_IPS
  fi
  if [[ -z "$HOME_ALLOW_IPS" ]]; then
    echo "    [!] 未配置 ALLOW_IPS，跳过家宽入口白名单防护。"
    echo "        建议重新运行: sudo ALLOW_IPS=普通机器公网IP bash setup-home-socks5.sh"
    return 0
  fi
  script_path="${SCRIPT_DIR}/setup-home-firewall-whitelist.sh"
  if [[ -f "$script_path" ]]; then
    ALLOW_IPS="$HOME_ALLOW_IPS" PROTECT_PORTS="$ports" LOCKDOWN_ALL="$HOME_FIREWALL_LOCKDOWN" bash "$script_path"
    return
  fi
  tmp_script="$(mktemp)"
  curl -fsSL "${RAW_BASE}/setup-home-firewall-whitelist.sh" -o "$tmp_script"
  ALLOW_IPS="$HOME_ALLOW_IPS" PROTECT_PORTS="$ports" LOCKDOWN_ALL="$HOME_FIREWALL_LOCKDOWN" bash "$tmp_script"
  rm -f "$tmp_script"
}

SOCKS_PORT="${SOCKS_PORT:-}"
SOCKS_USER="${SOCKS_USER:-}"
SOCKS_PASS="${SOCKS_PASS:-}"
SOCKS_HOST="${SOCKS_HOST:-}"
SOCKS_TCP_MSS="${SOCKS_TCP_MSS:-1200}"
STATE_DIR="/etc/home-socks5"
CONFIG_FILE="$STATE_DIR/config.env"
APPLY_BIN="/usr/local/sbin/home-socks5-apply"
CHECK_BIN="/usr/local/sbin/home-socks5-check"
RESTART_BIN="/usr/local/bin/home-socks5-restart"
HELPER_BIN="/usr/local/bin/home-socks5"
CHECK_UNIT_FILE="/etc/systemd/system/home-socks5-check.service"
CHECK_TIMER_FILE="/etc/systemd/system/home-socks5-check.timer"

if [[ -z "$SOCKS_PORT" ]]; then
  read -rp "SOCKS5 监听端口 [6013]: " SOCKS_PORT
  SOCKS_PORT="${SOCKS_PORT:-6013}"
fi
valid_port "$SOCKS_PORT" || { echo "SOCKS5 端口无效: $SOCKS_PORT"; exit 1; }
[[ "$SOCKS_TCP_MSS" =~ ^[0-9]+$ ]] && (( SOCKS_TCP_MSS >= 536 && SOCKS_TCP_MSS <= 1460 )) || {
  echo "SOCKS_TCP_MSS 无效: $SOCKS_TCP_MSS，应在 536-1460 之间。"
  exit 1
}

if [[ -z "$SOCKS_HOST" && -t 0 ]]; then
  echo "SOCKS5 对外连接地址应填写普通机器能连到的入口 IP/域名。"
  echo "如果家宽出口 IP 和入口 IP 不一致，不要填写 curl/ip.sb 看到的出口 IP。"
  read -rp "SOCKS5 对外连接地址/域名 [留空自动检测]: " SOCKS_HOST
fi

echo "==> 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq dante-server curl ca-certificates openssl iptables

WAN_IF="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
LOCAL_IP="$(ip -4 -o addr show dev "$WAN_IF" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
[[ -n "${WAN_IF:-}" && -n "${LOCAL_IP:-}" ]] || { echo "无法识别 IPv4 默认网卡/本机地址"; exit 1; }

if [[ -z "$SOCKS_USER" ]]; then
  SOCKS_USER="sock_$(gen_hex 4)"
fi
valid_user "$SOCKS_USER" || {
  echo "用户名无效: $SOCKS_USER"
  echo "要求: 小写字母或下划线开头，仅包含小写字母/数字/下划线/中横线，最长 31 位。"
  exit 1
}

if [[ -z "$SOCKS_PASS" ]]; then
  SOCKS_PASS="$(gen_hex 12)"
fi
[[ -n "$SOCKS_PASS" ]] || { echo "密码不能为空"; exit 1; }

echo "==> 创建 SOCKS5 用户"
if getent passwd "$SOCKS_USER" >/dev/null 2>&1; then
  usermod -s /usr/sbin/nologin "$SOCKS_USER" >/dev/null 2>&1 || true
else
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SOCKS_USER"
fi
printf '%s:%s\n' "$SOCKS_USER" "$SOCKS_PASS" | chpasswd

echo "==> 写入 /etc/danted.conf"
if [[ -f /etc/danted.conf ]]; then
  cp -a /etc/danted.conf "/etc/danted.conf.bak.$(date +%Y%m%d%H%M%S)"
fi
cat > /etc/danted.conf <<EOF
logoutput: syslog
user.privileged: root
user.unprivileged: nobody

internal: 0.0.0.0 port = ${SOCKS_PORT}
external: ${WAN_IF}

clientmethod: none
socksmethod: username

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect disconnect error
}

socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  command: bind connect udpassociate
  log: connect disconnect error
  socksmethod: username
}
EOF

echo "==> 放行本机防火墙端口"
if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p tcp --dport "$SOCKS_PORT" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport "$SOCKS_PORT" -j ACCEPT

  cat > /usr/local/sbin/apply-home-socks5-mss <<EOF
#!/usr/bin/env bash
set -e
PORT="${SOCKS_PORT}"
MSS="${SOCKS_TCP_MSS}"
iptables -t mangle -C PREROUTING -p tcp --dport "\$PORT" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS" 2>/dev/null || \\
  iptables -t mangle -I PREROUTING -p tcp --dport "\$PORT" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS"
iptables -t mangle -C OUTPUT -p tcp --sport "\$PORT" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS" 2>/dev/null || \\
  iptables -t mangle -I OUTPUT -p tcp --sport "\$PORT" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS"
EOF
  chmod +x /usr/local/sbin/apply-home-socks5-mss

  cat > /etc/systemd/system/home-socks5-mss.service <<'EOF'
[Unit]
Description=Clamp TCP MSS for home SOCKS5 service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/apply-home-socks5-mss

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now home-socks5-mss.service >/dev/null 2>&1 || true
else
  echo "    [!] 未找到 iptables，跳过本机防火墙放行。请确认系统/云防火墙已放行 TCP ${SOCKS_PORT}。"
fi
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${SOCKS_PORT}/tcp" >/dev/null || true
fi

echo "==> 启动 SOCKS5 服务"
systemctl enable danted >/dev/null 2>&1 || true
systemctl restart danted
sleep 1
systemctl --quiet is-active danted || {
  echo "danted 启动失败，最近日志:"
  journalctl -u danted -n 80 --no-pager || true
  exit 1
}

if [[ -z "$SOCKS_HOST" ]]; then
  SOCKS_HOST="$(curl -4 -fsS --connect-timeout 4 --max-time 8 https://ip.sb 2>/dev/null | tr -d '\r\n' || true)"
fi
if [[ -z "$SOCKS_HOST" ]]; then
  SOCKS_HOST="$(curl -4 -fsS --connect-timeout 4 --max-time 8 https://ifconfig.me 2>/dev/null | tr -d '\r\n' || true)"
fi
SOCKS_HOST="${SOCKS_HOST:-$LOCAL_IP}"
if [[ "$SOCKS_HOST" == "$LOCAL_IP" ]]; then
  echo "    [!] 未提供对外入口地址，已临时使用本机地址 ${SOCKS_HOST}。"
  echo "        如果普通机器不能连接这个地址，请重新运行并设置 SOCKS_HOST=入口IP或域名。"
fi

SOCKS_URL="socks5://${SOCKS_USER}:${SOCKS_PASS}@${SOCKS_HOST}:${SOCKS_PORT}"

echo "==> 写入持久化运维脚本"
mkdir -p "$STATE_DIR"
cat > "$CONFIG_FILE" <<EOF
SOCKS_PORT=${SOCKS_PORT}
SOCKS_USER=${SOCKS_USER}
SOCKS_HOST=${SOCKS_HOST}
SOCKS_TCP_MSS=${SOCKS_TCP_MSS}
WAN_IF=${WAN_IF}
LOCAL_IP=${LOCAL_IP}
EOF
chmod 600 "$CONFIG_FILE"

cat > "$APPLY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/home-socks5/config.env

current_wan="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
[[ -n "$current_wan" ]] && WAN_IF="$current_wan"

if ! grep -q "internal: 0.0.0.0 port = ${SOCKS_PORT}" /etc/danted.conf 2>/dev/null || ! grep -q "external: ${WAN_IF}" /etc/danted.conf 2>/dev/null; then
  sed -i "s/^internal:.*/internal: 0.0.0.0 port = ${SOCKS_PORT}/; s/^external:.*/external: ${WAN_IF}/" /etc/danted.conf
fi

iptables -C INPUT -p tcp --dport "$SOCKS_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$SOCKS_PORT" -j ACCEPT
iptables -t mangle -C PREROUTING -p tcp --dport "$SOCKS_PORT" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$SOCKS_TCP_MSS" 2>/dev/null || iptables -t mangle -I PREROUTING -p tcp --dport "$SOCKS_PORT" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$SOCKS_TCP_MSS"
iptables -t mangle -C OUTPUT -p tcp --sport "$SOCKS_PORT" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$SOCKS_TCP_MSS" 2>/dev/null || iptables -t mangle -I OUTPUT -p tcp --sport "$SOCKS_PORT" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$SOCKS_TCP_MSS"

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${SOCKS_PORT}/tcp" >/dev/null || true
fi

if ! systemctl is-active --quiet danted; then
  systemctl restart danted
fi

tmp="$(mktemp)"
awk -v wan="$WAN_IF" 'BEGIN{done=0} /^WAN_IF=/{print "WAN_IF=" wan; done=1; next} {print} END{if(!done) print "WAN_IF=" wan}' /etc/home-socks5/config.env > "$tmp"
cat "$tmp" > /etc/home-socks5/config.env
rm -f "$tmp"
EOF
chmod 755 "$APPLY_BIN"

cat > "$CHECK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/home-socks5/config.env

repair=0
need_repair() {
  repair=1
  logger -t home-socks5-check "$*"
}

current_wan="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
[[ -n "$current_wan" && "$current_wan" != "${WAN_IF:-}" ]] && need_repair "WAN interface changed: ${WAN_IF:-unknown} -> ${current_wan}"
systemctl is-active --quiet danted || need_repair "danted is not running"
ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\.)${SOCKS_PORT}$" || need_repair "SOCKS5 port ${SOCKS_PORT} is not listening"
iptables -C INPUT -p tcp --dport "$SOCKS_PORT" -j ACCEPT 2>/dev/null || need_repair "missing TCP input rule"
iptables -t mangle -C PREROUTING -p tcp --dport "$SOCKS_PORT" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$SOCKS_TCP_MSS" 2>/dev/null || need_repair "missing PREROUTING MSS rule"
iptables -t mangle -C OUTPUT -p tcp --sport "$SOCKS_PORT" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$SOCKS_TCP_MSS" 2>/dev/null || need_repair "missing OUTPUT MSS rule"

if (( repair )); then
  /usr/local/sbin/home-socks5-apply
fi
EOF
chmod 755 "$CHECK_BIN"

cat > "$RESTART_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl restart danted
/usr/local/sbin/home-socks5-apply
systemctl enable --now home-socks5-check.timer >/dev/null
systemctl start home-socks5-check.service >/dev/null 2>&1 || true
home-socks5 status
EOF
chmod 755 "$RESTART_BIN"

cat > "$HELPER_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/home-socks5/config.env
case "${1:-status}" in
  status) systemctl status danted home-socks5-check.timer --no-pager --lines=8; ss -ltnp 2>/dev/null | grep ":${SOCKS_PORT}" || true ;;
  check|repair) /usr/local/sbin/home-socks5-check ;;
  apply) /usr/local/sbin/home-socks5-apply ;;
  restart) /usr/local/bin/home-socks5-restart ;;
  logs) journalctl -u danted -u home-socks5-check.service --no-pager "${@:2}" ;;
  *) echo "usage: home-socks5 status|check|apply|restart|logs" >&2; exit 2 ;;
esac
EOF
chmod 755 "$HELPER_BIN"

cat > "$CHECK_UNIT_FILE" <<EOF
[Unit]
Description=Home SOCKS5 self-healing check
After=network-online.target danted.service home-socks5-mss.service
Wants=network-online.target danted.service

[Service]
Type=oneshot
ExecStart=${CHECK_BIN}
EOF

cat > "$CHECK_TIMER_FILE" <<'EOF'
[Unit]
Description=Run Home SOCKS5 self-healing check

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true
Unit=home-socks5-check.service

[Install]
WantedBy=timers.target
EOF

mkdir -p /etc/systemd/system/danted.service.d
cat > /etc/systemd/system/danted.service.d/10-home-socks5-restart.conf <<'EOF'
[Service]
Restart=on-failure
RestartSec=5s
EOF
systemctl daemon-reload
systemctl enable --now home-socks5-check.timer >/dev/null 2>&1 || true
setup_home_firewall_whitelist "${SOCKS_PORT}/tcp"

echo "==> 本机连通性测试"
if curl -4 -fsS --connect-timeout 8 --max-time 20 --proxy "socks5h://${SOCKS_USER}:${SOCKS_PASS}@127.0.0.1:${SOCKS_PORT}" https://ip.sb >/tmp/home-socks5-test.out 2>/tmp/home-socks5-test.err; then
  echo "    [OK] SOCKS5 本机测试通过，出口 IP: $(tr -d '\r\n' </tmp/home-socks5-test.out)"
else
  echo "    [!] SOCKS5 本机测试失败，但服务已启动。可查看: journalctl -u danted -n 80 --no-pager"
fi

echo
echo "============================================================"
echo " 家宽 SOCKS5 服务端配置完成"
echo "------------------------------------------------------------"
echo " 网卡:      ${WAN_IF}"
echo " 监听:      0.0.0.0:${SOCKS_PORT}"
echo " TCP MSS:   ${SOCKS_TCP_MSS}"
echo " 用户名:    ${SOCKS_USER}"
echo " 密码:      ${SOCKS_PASS}"
echo " SOCKS5:    ${SOCKS_URL}"
echo "------------------------------------------------------------"
echo " 普通机器接入:"
echo "   sudo zck proxy add '${SOCKS_URL}'"
echo "   sudo zck proxy switch"
echo "   sudo zck test"
echo "------------------------------------------------------------"
echo " 注意: 云防火墙/路由器也需要放行 TCP ${SOCKS_PORT}。"
echo " 自修复: home-socks5-check.timer 每 60 秒检查服务/端口/规则"
echo " 管理: home-socks5 status | home-socks5 restart | home-socks5 logs -n 80"
echo "============================================================"
