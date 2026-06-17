#!/usr/bin/env bash
# 普通 VPS 持久化 SSH SOCKS 代理隧道一键脚本（客户端侧）
# 功能: 在本机建立到家宽/上游机器的 `ssh -N -D` 动态 SOCKS5 隧道，
#       本机 127.0.0.1:<端口> 即为家宽出口，可配合 setup-egress-socks.sh 把出口切过去。
# 特性: systemd 常驻 + 断线自动重连 + SSH 保活 + 自愈定时检查 + 免密公钥登录。
# 用法: sudo bash setup-ssh-socks.sh
# 可选(环境变量覆盖交互):
#   sudo SSH_HOST=vm111.example.com SSH_PORT=2311 SSH_USER=debian SOCKS_PORT=1080 bash setup-ssh-socks.sh
#   sudo SSH_CMD='ssh -N -D 1080 -p 2311 debian@vm111.example.com' bash setup-ssh-socks.sh
#   sudo BIND_ADDR=127.0.0.1 bash setup-ssh-socks.sh        # 监听地址，默认仅本机
set -euo pipefail
trap 'echo "[ERROR] 脚本在第 ${LINENO} 行退出: ${BASH_COMMAND}" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "需要 root 权限 (sudo)"; exit 1; }
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu"; exit 1; }

SSH_HOST="${SSH_HOST:-}"
SSH_PORT="${SSH_PORT:-}"
SSH_USER="${SSH_USER:-}"
SOCKS_PORT="${SOCKS_PORT:-}"
SSH_CMD="${SSH_CMD:-}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"

SVC_USER="sshsocks"
SVC_HOME="/var/lib/ssh-socks"
STATE_DIR="/etc/ssh-socks"
CONFIG_FILE="$STATE_DIR/config.env"
KEY_FILE="$SVC_HOME/.ssh/id_ed25519"
KNOWN_HOSTS="$SVC_HOME/.ssh/known_hosts"
SERVICE_FILE="/etc/systemd/system/ssh-socks.service"
CHECK_BIN="/usr/local/sbin/ssh-socks-check"
APPLY_BIN="/usr/local/sbin/ssh-socks-apply"
HELPER_BIN="/usr/local/bin/ssh-socks"
CHECK_UNIT_FILE="/etc/systemd/system/ssh-socks-check.service"
CHECK_TIMER_FILE="/etc/systemd/system/ssh-socks-check.timer"
FAIL_COUNTER="/run/ssh-socks-probe-fails"

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )); }
valid_host() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
valid_user() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

# parse_ssh_cmd: 从一整条 `ssh -N -D 1080 -p 2311 debian@host` 命令里提取参数。
parse_ssh_cmd() {
  local -a toks
  read -r -a toks <<< "$1"
  local i=0 n=${#toks[@]} t next
  while (( i < n )); do
    t="${toks[$i]}"
    next="${toks[$((i+1))]:-}"
    case "$t" in
      -D)
        # -D 值可能是 "1080" 或 "127.0.0.1:1080"
        [[ -z "$SOCKS_PORT" ]] && SOCKS_PORT="${next##*:}"
        i=$((i+2)); continue ;;
      -p)
        [[ -z "$SSH_PORT" ]] && SSH_PORT="$next"
        i=$((i+2)); continue ;;
      -i|-L|-R|-o|-b|-c|-l)
        i=$((i+2)); continue ;;  # 跳过这些选项及其参数
      *@*)
        [[ -z "$SSH_USER" ]] && SSH_USER="${t%@*}"
        [[ -z "$SSH_HOST" ]] && SSH_HOST="${t#*@}"
        ;;
    esac
    i=$((i+1))
  done
}

if [[ -z "$SSH_CMD" && -z "$SSH_HOST" && -t 0 ]]; then
  echo "可直接粘贴完整 ssh 命令（如: ssh -N -D 1080 -p 2311 debian@vm111.example.com）"
  read -rp "ssh 命令 [留空则逐项输入]: " SSH_CMD
fi
[[ -n "$SSH_CMD" ]] && parse_ssh_cmd "$SSH_CMD"

if [[ -z "$SSH_HOST" && -t 0 ]]; then
  read -rp "上游/家宽 SSH 主机 (IP 或域名): " SSH_HOST
fi
[[ -n "$SSH_HOST" ]] || { echo "必须提供 SSH 主机"; exit 1; }
valid_host "$SSH_HOST" || { echo "主机格式无效: $SSH_HOST"; exit 1; }

if [[ -z "$SSH_PORT" && -t 0 ]]; then
  read -rp "SSH 端口 [22]: " SSH_PORT
fi
SSH_PORT="${SSH_PORT:-22}"
valid_port "$SSH_PORT" || { echo "SSH 端口无效: $SSH_PORT"; exit 1; }

if [[ -z "$SSH_USER" && -t 0 ]]; then
  read -rp "SSH 用户名 (如 debian): " SSH_USER
fi
[[ -n "$SSH_USER" ]] || { echo "必须提供 SSH 用户名"; exit 1; }
valid_user "$SSH_USER" || { echo "用户名格式无效: $SSH_USER"; exit 1; }

if [[ -z "$SOCKS_PORT" && -t 0 ]]; then
  read -rp "本地 SOCKS5 监听端口 [1080]: " SOCKS_PORT
fi
SOCKS_PORT="${SOCKS_PORT:-1080}"
valid_port "$SOCKS_PORT" || { echo "SOCKS 端口无效: $SOCKS_PORT"; exit 1; }

if [[ "$BIND_ADDR" != "127.0.0.1" && "$BIND_ADDR" != "::1" && "$BIND_ADDR" != "localhost" ]]; then
  echo "    [!] 警告: SSH 动态转发(-D)没有认证机制，绑定到 ${BIND_ADDR} 会把代理暴露给外部。"
  echo "        强烈建议保持 127.0.0.1，并用 setup-egress-socks.sh 让本机其他服务接入。"
  if [[ -t 0 ]]; then
    read -rp "确认绑定到 ${BIND_ADDR}? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "已取消"; exit 1; }
  fi
fi

echo "==> 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq openssh-client curl ca-certificates iproute2

echo "==> 创建隧道运行用户 ${SVC_USER}"
if ! getent passwd "$SVC_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$SVC_HOME" --create-home --shell /usr/sbin/nologin "$SVC_USER"
fi
install -d -m 700 -o "$SVC_USER" -g "$SVC_USER" "$SVC_HOME/.ssh"

echo "==> 准备 SSH 密钥"
if [[ ! -f "$KEY_FILE" ]]; then
  sudo -u "$SVC_USER" ssh-keygen -t ed25519 -N "" -C "ssh-socks@$(hostname)" -f "$KEY_FILE" >/dev/null
fi
PUBKEY="$(cat "${KEY_FILE}.pub")"

echo "==> 预置 known_hosts (accept-new)"
touch "$KNOWN_HOSTS"; chown "$SVC_USER:$SVC_USER" "$KNOWN_HOSTS"; chmod 644 "$KNOWN_HOSTS"
sudo -u "$SVC_USER" ssh-keyscan -p "$SSH_PORT" -H "$SSH_HOST" >> "$KNOWN_HOSTS" 2>/dev/null || \
  echo "    [!] ssh-keyscan 暂时失败，首次连接将以 accept-new 自动信任。"

# 检测是否已免密；未免密则尝试用 ssh-copy-id 安装公钥（需要交互输入一次远程密码）。
echo "==> 检测免密登录"
KEY_OK=0
if sudo -u "$SVC_USER" ssh -p "$SSH_PORT" -i "$KEY_FILE" \
     -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
     -o UserKnownHostsFile="$KNOWN_HOSTS" -o IdentitiesOnly=yes \
     "${SSH_USER}@${SSH_HOST}" true 2>/dev/null; then
  KEY_OK=1
  echo "    [OK] 公钥已生效，免密登录可用。"
elif [[ -t 0 ]]; then
  echo "    需要把本机公钥安装到上游 ${SSH_USER}@${SSH_HOST}，下面请输入该账号的【SSH 登录密码】:"
  if sudo -u "$SVC_USER" ssh-copy-id -p "$SSH_PORT" -i "${KEY_FILE}.pub" \
       -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS" \
       "${SSH_USER}@${SSH_HOST}"; then
    KEY_OK=1
    echo "    [OK] 公钥已安装。"
  fi
fi
if (( ! KEY_OK )); then
  echo "    [!] 免密登录尚未就绪。请在上游机器手动追加以下公钥到 ~${SSH_USER}/.ssh/authorized_keys 后重跑本脚本:"
  echo
  echo "        ${PUBKEY}"
  echo
fi

echo "==> 写入配置"
install -d -m 755 "$STATE_DIR"
cat > "$CONFIG_FILE" <<EOF
SSH_HOST=${SSH_HOST}
SSH_PORT=${SSH_PORT}
SSH_USER=${SSH_USER}
SOCKS_PORT=${SOCKS_PORT}
BIND_ADDR=${BIND_ADDR}
SVC_USER=${SVC_USER}
KEY_FILE=${KEY_FILE}
KNOWN_HOSTS=${KNOWN_HOSTS}
EOF
chmod 644 "$CONFIG_FILE"

echo "==> 写入 systemd 隧道服务"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Persistent SSH SOCKS proxy tunnel to ${SSH_USER}@${SSH_HOST}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
User=${SVC_USER}
# ExitOnForwardFailure=yes 让端口被占/转发失败时 ssh 立即退出，交由 systemd 重启。
# ServerAliveInterval/CountMax 在链路假死(NAT 超时、对端无响应)时主动断开触发重连。
ExecStart=/usr/bin/ssh -N -D ${BIND_ADDR}:${SOCKS_PORT} -p ${SSH_PORT} \\
  -i ${KEY_FILE} \\
  -o IdentitiesOnly=yes \\
  -o BatchMode=yes \\
  -o ExitOnForwardFailure=yes \\
  -o ServerAliveInterval=15 \\
  -o ServerAliveCountMax=3 \\
  -o TCPKeepAlive=yes \\
  -o ConnectTimeout=10 \\
  -o StrictHostKeyChecking=accept-new \\
  -o UserKnownHostsFile=${KNOWN_HOSTS} \\
  ${SSH_USER}@${SSH_HOST}
Restart=always
RestartSec=5
# 隧道偶发退出不应触发限速，始终重连。
[Install]
WantedBy=multi-user.target
EOF

echo "==> 写入自愈与运维脚本"
cat > "$APPLY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl daemon-reload
systemctl enable ssh-socks.service >/dev/null 2>&1 || true
systemctl restart ssh-socks.service
EOF
chmod 755 "$APPLY_BIN"

cat > "$CHECK_BIN" <<'EOF'
#!/usr/bin/env bash
# 自愈检查: 服务未运行或端口未监听立即重启; SOCKS 出口探测连续失败 3 次才重启,
# 避免目标站点偶发抖动造成误杀正常隧道。
set -euo pipefail
source /etc/ssh-socks/config.env
COUNTER="/run/ssh-socks-probe-fails"

restart() { logger -t ssh-socks-check "repair: $*"; systemctl restart ssh-socks.service; rm -f "$COUNTER"; exit 0; }

systemctl is-active --quiet ssh-socks.service || restart "service not active"
ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\.)${SOCKS_PORT}$" || restart "port ${SOCKS_PORT} not listening"

# 出口探测: 经本地 SOCKS 访问外网, 失败累计计数。
if curl -fsS --connect-timeout 8 --max-time 20 \
     --proxy "socks5h://${BIND_ADDR}:${SOCKS_PORT}" https://ip.sb >/dev/null 2>&1; then
  rm -f "$COUNTER"
else
  fails=$(( $(cat "$COUNTER" 2>/dev/null || echo 0) + 1 ))
  echo "$fails" > "$COUNTER"
  logger -t ssh-socks-check "egress probe failed (${fails}/3)"
  (( fails >= 3 )) && restart "egress probe failed ${fails} times"
fi
EOF
chmod 755 "$CHECK_BIN"

cat > "$HELPER_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/ssh-socks/config.env
case "${1:-status}" in
  status)
    systemctl status ssh-socks.service ssh-socks-check.timer --no-pager --lines=8 || true
    ss -ltnp 2>/dev/null | grep ":${SOCKS_PORT}" || true ;;
  restart) /usr/local/sbin/ssh-socks-apply; ssh-socks status ;;
  check|repair) /usr/local/sbin/ssh-socks-check ;;
  test)
    echo "经 socks5h://${BIND_ADDR}:${SOCKS_PORT} 测试出口 IP:"
    curl -fsS --connect-timeout 8 --max-time 20 --proxy "socks5h://${BIND_ADDR}:${SOCKS_PORT}" https://ip.sb || echo "测试失败" ;;
  show) echo "socks5://${BIND_ADDR}:${SOCKS_PORT}  ->  ${SSH_USER}@${SSH_HOST}:${SSH_PORT}" ;;
  logs) journalctl -u ssh-socks.service -u ssh-socks-check.service --no-pager "${@:2}" ;;
  *) echo "usage: ssh-socks status|restart|check|test|show|logs" >&2; exit 2 ;;
esac
EOF
chmod 755 "$HELPER_BIN"

cat > "$CHECK_UNIT_FILE" <<EOF
[Unit]
Description=SSH SOCKS tunnel self-healing check
After=network-online.target ssh-socks.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CHECK_BIN}
EOF

cat > "$CHECK_TIMER_FILE" <<'EOF'
[Unit]
Description=Run SSH SOCKS tunnel self-healing check

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true
Unit=ssh-socks-check.service

[Install]
WantedBy=timers.target
EOF

echo "==> 启动服务"
systemctl daemon-reload
systemctl enable --now ssh-socks.service >/dev/null 2>&1 || true
systemctl enable --now ssh-socks-check.timer >/dev/null 2>&1 || true
sleep 2

if systemctl --quiet is-active ssh-socks.service; then
  echo "    [OK] 隧道服务已运行。"
else
  echo "    [!] 隧道服务未运行，最近日志:"
  journalctl -u ssh-socks.service -n 30 --no-pager || true
fi

echo "==> 出口连通性测试"
if curl -fsS --connect-timeout 8 --max-time 20 --proxy "socks5h://${BIND_ADDR}:${SOCKS_PORT}" https://ip.sb >/tmp/ssh-socks-test.out 2>/dev/null; then
  echo "    [OK] SOCKS 出口 IP: $(tr -d '\r\n' </tmp/ssh-socks-test.out)"
else
  echo "    [!] 出口测试失败。若刚装好公钥可稍等几秒后执行: ssh-socks test"
fi

echo
echo "============================================================"
echo " 持久化 SSH SOCKS 代理隧道配置完成"
echo "------------------------------------------------------------"
echo " 上游:    ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
echo " 本地代理: socks5://${BIND_ADDR}:${SOCKS_PORT}"
echo "------------------------------------------------------------"
echo " 配合家宽出口(把本机/小鸡出口切到此 SOCKS):"
echo "   sudo bash setup-egress-socks.sh    # 选择上游 SOCKS = ${BIND_ADDR}:${SOCKS_PORT}"
echo "------------------------------------------------------------"
echo " 常驻: systemd ssh-socks.service (Restart=always, SSH 保活自动重连)"
echo " 自愈: ssh-socks-check.timer 每 60s 检查服务/端口/出口"
echo " 管理: ssh-socks status | ssh-socks restart | ssh-socks test | ssh-socks logs -n 80"
echo "============================================================"
