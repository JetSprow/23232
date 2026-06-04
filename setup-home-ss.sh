#!/usr/bin/env bash
# 家宽 VPS Shadowsocks 服务端一键脚本
# 用法:
#   sudo bash setup-home-ss.sh
#   sudo SS_HOST=入口IP或域名 SS_PORT=6013 bash setup-home-ss.sh
#   sudo SS_METHOD=aes-256-gcm SS_PASSWORD=yourpass bash setup-home-ss.sh
set -euo pipefail
trap 'echo "[ERROR] 脚本在第 ${LINENO} 行退出: ${BASH_COMMAND}" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "需要 root 权限 (sudo)"; exit 1; }
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu"; exit 1; }

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

gen_hex() {
  openssl rand -hex "$1"
}

install_singbox() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gpg openssl iptables

  mkdir -p /etc/apt/keyrings
  if [[ ! -s /etc/apt/keyrings/sagernet.asc ]]; then
    curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
    chmod a+r /etc/apt/keyrings/sagernet.asc
  fi
  cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
  apt-get update -qq
  apt-get install -y -qq sing-box
}

SS_PORT="${SS_PORT:-}"
SS_HOST="${SS_HOST:-}"
SS_METHOD="${SS_METHOD:-aes-256-gcm}"
SS_PASSWORD="${SS_PASSWORD:-}"
STATE_DIR="/etc/home-ss"
CONFIG_FILE="$STATE_DIR/config.env"
APPLY_BIN="/usr/local/sbin/home-ss-apply"
CHECK_BIN="/usr/local/sbin/home-ss-check"
RESTART_BIN="/usr/local/bin/home-ss-restart"
HELPER_BIN="/usr/local/bin/home-ss"
CHECK_UNIT_FILE="/etc/systemd/system/home-ss-check.service"
CHECK_TIMER_FILE="/etc/systemd/system/home-ss-check.timer"

if [[ -z "$SS_PORT" ]]; then
  read -rp "Shadowsocks 监听端口 [6013]: " SS_PORT
  SS_PORT="${SS_PORT:-6013}"
fi
valid_port "$SS_PORT" || { echo "Shadowsocks 端口无效: $SS_PORT"; exit 1; }

if [[ -z "$SS_HOST" && -t 0 ]]; then
  echo "SS 对外连接地址应填写普通机器能连到的入口 IP/域名。"
  read -rp "SS 对外连接地址/域名 [留空自动检测]: " SS_HOST
fi

if [[ -z "$SS_PASSWORD" ]]; then
  SS_PASSWORD="$(gen_hex 16)"
fi
[[ -n "$SS_PASSWORD" ]] || { echo "SS_PASSWORD 不能为空"; exit 1; }

echo "==> 安装 sing-box"
install_singbox

WAN_IF="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
LOCAL_IP="$(ip -4 -o addr show dev "$WAN_IF" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
[[ -n "${WAN_IF:-}" && -n "${LOCAL_IP:-}" ]] || { echo "无法识别 IPv4 默认网卡/本机地址"; exit 1; }

echo "==> 写入 /etc/sing-box/home-ss.json"
mkdir -p /etc/sing-box
chmod 700 /etc/sing-box
cat > /etc/sing-box/home-ss.json <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "0.0.0.0",
      "listen_port": ${SS_PORT},
      "method": "${SS_METHOD}",
      "password": "${SS_PASSWORD}",
      "network": "tcp"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF
chmod 600 /etc/sing-box/home-ss.json

echo "==> 写入 systemd 服务"
cat > /etc/systemd/system/home-ss.service <<'EOF'
[Unit]
Description=Home Shadowsocks Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/home-ss.json
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

echo "==> 停止可能占用端口的旧 SOCKS5 服务"
systemctl disable --now danted >/dev/null 2>&1 || true
systemctl disable --now home-socks5-mss >/dev/null 2>&1 || true
pkill -x microsocks >/dev/null 2>&1 || true

echo "==> 放行本机防火墙端口"
if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p tcp --dport "$SS_PORT" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport "$SS_PORT" -j ACCEPT
else
  echo "    [!] 未找到 iptables，跳过本机防火墙放行。请确认系统/云防火墙已放行 TCP ${SS_PORT}。"
fi
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${SS_PORT}/tcp" >/dev/null || true
fi

echo "==> 启动 Shadowsocks 服务"
systemctl daemon-reload
systemctl enable --now home-ss.service >/dev/null 2>&1 || true
sleep 1
systemctl --quiet is-active home-ss.service || {
  echo "home-ss 启动失败，最近日志:"
  journalctl -u home-ss -n 80 --no-pager || true
  exit 1
}

if [[ -z "$SS_HOST" ]]; then
  SS_HOST="$(curl -4 -fsS --connect-timeout 4 --max-time 8 https://ip.sb 2>/dev/null | tr -d '\r\n' || true)"
fi
if [[ -z "$SS_HOST" ]]; then
  SS_HOST="$(curl -4 -fsS --connect-timeout 4 --max-time 8 https://ifconfig.me 2>/dev/null | tr -d '\r\n' || true)"
fi
SS_HOST="${SS_HOST:-$LOCAL_IP}"

SS_URL="ss://${SS_METHOD}:${SS_PASSWORD}@${SS_HOST}:${SS_PORT}"

echo "==> 写入持久化运维脚本"
mkdir -p "$STATE_DIR"
cat > "$CONFIG_FILE" <<EOF
SS_PORT=${SS_PORT}
SS_HOST=${SS_HOST}
SS_METHOD=${SS_METHOD}
WAN_IF=${WAN_IF}
LOCAL_IP=${LOCAL_IP}
EOF
chmod 600 "$CONFIG_FILE"

cat > "$APPLY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/home-ss/config.env

current_wan="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
[[ -n "$current_wan" ]] && WAN_IF="$current_wan"

iptables -C INPUT -p tcp --dport "$SS_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$SS_PORT" -j ACCEPT
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${SS_PORT}/tcp" >/dev/null || true
fi

if ! systemctl is-active --quiet home-ss.service; then
  systemctl restart home-ss.service
fi

tmp="$(mktemp)"
awk -v wan="$WAN_IF" 'BEGIN{done=0} /^WAN_IF=/{print "WAN_IF=" wan; done=1; next} {print} END{if(!done) print "WAN_IF=" wan}' /etc/home-ss/config.env > "$tmp"
cat "$tmp" > /etc/home-ss/config.env
rm -f "$tmp"
EOF
chmod 755 "$APPLY_BIN"

cat > "$CHECK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/home-ss/config.env

repair=0
need_repair() {
  repair=1
  logger -t home-ss-check "$*"
}

current_wan="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
[[ -n "$current_wan" && "$current_wan" != "${WAN_IF:-}" ]] && need_repair "WAN interface changed: ${WAN_IF:-unknown} -> ${current_wan}"
systemctl is-active --quiet home-ss.service || need_repair "home-ss is not running"
ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\.)${SS_PORT}$" || need_repair "SS port ${SS_PORT} is not listening"
iptables -C INPUT -p tcp --dport "$SS_PORT" -j ACCEPT 2>/dev/null || need_repair "missing TCP input rule"

if (( repair )); then
  /usr/local/sbin/home-ss-apply
fi
EOF
chmod 755 "$CHECK_BIN"

cat > "$RESTART_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl restart home-ss.service
/usr/local/sbin/home-ss-apply
systemctl enable --now home-ss-check.timer >/dev/null
systemctl start home-ss-check.service >/dev/null 2>&1 || true
home-ss status
EOF
chmod 755 "$RESTART_BIN"

cat > "$HELPER_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/home-ss/config.env
case "${1:-status}" in
  status) systemctl status home-ss.service home-ss-check.timer --no-pager --lines=8; ss -ltnp 2>/dev/null | grep ":${SS_PORT}" || true ;;
  check|repair) /usr/local/sbin/home-ss-check ;;
  apply) /usr/local/sbin/home-ss-apply ;;
  restart) /usr/local/bin/home-ss-restart ;;
  logs) journalctl -u home-ss.service -u home-ss-check.service --no-pager "${@:2}" ;;
  *) echo "usage: home-ss status|check|apply|restart|logs" >&2; exit 2 ;;
esac
EOF
chmod 755 "$HELPER_BIN"

cat > "$CHECK_UNIT_FILE" <<EOF
[Unit]
Description=Home Shadowsocks self-healing check
After=network-online.target home-ss.service
Wants=network-online.target home-ss.service

[Service]
Type=oneshot
ExecStart=${CHECK_BIN}
EOF

cat > "$CHECK_TIMER_FILE" <<'EOF'
[Unit]
Description=Run Home Shadowsocks self-healing check

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true
Unit=home-ss-check.service

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now home-ss-check.timer >/dev/null 2>&1 || true

echo
echo "============================================================"
echo " 家宽 Shadowsocks 服务端配置完成"
echo "------------------------------------------------------------"
echo " 网卡:      ${WAN_IF}"
echo " 监听:      0.0.0.0:${SS_PORT}"
echo " 加密:      ${SS_METHOD}"
echo " 密码:      ${SS_PASSWORD}"
echo " SS:        ${SS_URL}"
echo "------------------------------------------------------------"
echo " 普通机器接入:"
echo "   sudo zck proxy add '${SS_URL}'"
echo "   sudo zck proxy switch"
echo "   sudo zck restart"
echo "   sudo zck test"
echo "------------------------------------------------------------"
echo " 注意: 云防火墙/路由器也需要放行 TCP ${SS_PORT}。"
echo " 自修复: home-ss-check.timer 每 60 秒检查服务/端口/规则"
echo " 管理: home-ss status | home-ss restart | home-ss logs -n 80"
echo "============================================================"
