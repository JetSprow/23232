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
echo " 日志: journalctl -u home-ss -f --no-pager"
echo "============================================================"
