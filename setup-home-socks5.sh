#!/usr/bin/env bash
# 家宽 VPS SOCKS5 服务端一键脚本
# 功能: 安装 dante-server，创建用户名密码，输出 socks5://用户名:密码@地址:端口
# 用法: sudo bash setup-home-socks5.sh
# 可选:
#   sudo SOCKS_PORT=6013 bash setup-home-socks5.sh
#   sudo SOCKS_HOST=home.example.com SOCKS_PORT=6013 bash setup-home-socks5.sh
#   sudo SOCKS_PORT=6013 SOCKS_USER=myuser SOCKS_PASS=mypass bash setup-home-socks5.sh
set -euo pipefail
trap 'echo "[ERROR] 脚本在第 ${LINENO} 行退出: ${BASH_COMMAND}" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "需要 root 权限 (sudo)"; exit 1; }
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu"; exit 1; }

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

valid_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]
}

gen_hex() {
  openssl rand -hex "$1"
}

SOCKS_PORT="${SOCKS_PORT:-}"
SOCKS_USER="${SOCKS_USER:-}"
SOCKS_PASS="${SOCKS_PASS:-}"
SOCKS_HOST="${SOCKS_HOST:-}"

if [[ -z "$SOCKS_PORT" ]]; then
  read -rp "SOCKS5 监听端口 [6013]: " SOCKS_PORT
  SOCKS_PORT="${SOCKS_PORT:-6013}"
fi
valid_port "$SOCKS_PORT" || { echo "SOCKS5 端口无效: $SOCKS_PORT"; exit 1; }

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
echo " 日志: journalctl -u danted -f --no-pager"
echo "============================================================"
