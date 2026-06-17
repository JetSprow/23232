#!/usr/bin/env bash
# =============================================================================
# Egress SOCKS5 installer for Incus nodes (v2 — simplified, no auto_redirect)
# =============================================================================
#
# Goal:
#   • Node (host)         egress → SOCKS5
#   • Incus guests        egress → SOCKS5
#   • User port forwarding (host:<port> → guest:<port>) keeps working
#   • SSH and panel/control-plane access keep working
#
# Design (intentionally boring):
#
#   1. sing-box runs with a TUN inbound and `auto_route: true`. That alone
#      makes every host- and guest-originated packet go through sing-box,
#      which then routes through the upstream SOCKS5.
#
#   2. A tiny systemd unit `egress-bypass.service` installs nft rules +
#      an ip-rule so that *return packets of inbound connections* skip
#      the TUN and use the host's original default route:
#         - tcp sport 22                → SSH replies
#         - tcp sport 8443              → Incus API replies
#         - tcp/udp sport 20000-30000   → user port-forwarding replies
#                                         (after conntrack reverse-NAT)
#      These flows must not be reproxied or the original peer drops them.
#
#   3. No `auto_redirect`. That feature has many edge cases (DNS
#      validation, Docker/Incus nft conflicts, OUTPUT-chain semantics)
#      that have repeatedly broken this setup. The explicit bypass above
#      gives us exactly the behaviour we need with two systemd units and
#      one nft table — easy to read, easy to debug.
#
# Two systemd units installed:
#   egress-bypass.service   nft + ip rule, starts before sing-box
#   sing-box.service        upstream sing-box package
#
# Helper:
#   /usr/local/bin/zck      status | test | diag | logs | check | restart | off | on
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Upstream SOCKS5 endpoint.
# Prefer passing a full URL, or enter it interactively on first install:
#   sudo BUILTIN_PROXY_URL='socks5://user:pass@1.2.3.4:6013' bash setup-egress-socks.sh
#   sudo BUILTIN_PROXY_URL='ss://aes-256-gcm:pass@1.2.3.4:6013' bash setup-egress-socks.sh
# Legacy split env vars are still supported:
#   sudo BUILTIN_PROXY_HOST=1.2.3.4 BUILTIN_PROXY_PORT=6013 ... bash setup-egress-socks.sh
# -----------------------------------------------------------------------------
BUILTIN_PROXY_URL="${BUILTIN_PROXY_URL:-}"
BUILTIN_PROXY_HOST="${BUILTIN_PROXY_HOST:-}"
BUILTIN_PROXY_PORT="${BUILTIN_PROXY_PORT:-}"
BUILTIN_PROXY_USER="${BUILTIN_PROXY_USER:-}"
BUILTIN_PROXY_PASS="${BUILTIN_PROXY_PASS:-}"

# -----------------------------------------------------------------------------
# Network defaults (env-overridable).
# -----------------------------------------------------------------------------
DETECTED_SSH_PORT="22"
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  DETECTED_SSH_PORT="$(printf '%s' "$SSH_CONNECTION" | awk '{print $4}')"
  [[ "$DETECTED_SSH_PORT" =~ ^[0-9]+$ ]] || DETECTED_SSH_PORT="22"
fi
INCUS_SUBNET="${INCUS_SUBNET:-10.10.0.0/22}"
INCUS_BRIDGE="${INCUS_BRIDGE:-incusbr0}"
NODE_SSH_PORT="${NODE_SSH_PORT:-$DETECTED_SSH_PORT}"
INCUS_API_PORT="${INCUS_API_PORT:-8443}"
PORT_RANGE_LOW="${PORT_RANGE_LOW:-20000}"
PORT_RANGE_HIGH="${PORT_RANGE_HIGH:-30000}"
BOOTSTRAP_DNS="${BOOTSTRAP_DNS:-1.1.1.1}"
TUN_IPV6="${TUN_IPV6:-0}"
EGRESS_PROBE_URL="${EGRESS_PROBE_URL:-https://ip.sb}"
EGRESS_CONNECT_TIMEOUT="${EGRESS_CONNECT_TIMEOUT:-12}"
EGRESS_MAX_TIME="${EGRESS_MAX_TIME:-35}"
EGRESS_RETRIES="${EGRESS_RETRIES:-2}"
TG_BOT_TOKEN="${TG_BOT_TOKEN:-8701916491:AAGFJ3FEA6oRe3gFHYXwN_8zNGmEM9fb-TY}"
TG_CHAT_ID="${TG_CHAT_ID:--1003891322020}"
REPORT_NODE_NAME="${REPORT_NODE_NAME:-}"

# -----------------------------------------------------------------------------
# Internals — generally don't need editing.
# -----------------------------------------------------------------------------
TUN_NAME="egress-tun0"
TUN_ADDR4="172.19.0.1/30"
TUN_ADDR6="fdfe:dcba:9876::1/126"

BYPASS_MARK_HEX="0x42"
BYPASS_RULE_PREF="8000"     # must be less than SINGBOX_RULE_INDEX
SINGBOX_TABLE_INDEX="2022"
SINGBOX_RULE_INDEX="9000"

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
STATE_DIR="/etc/egress-socks"
HELPER_BIN="/usr/local/bin/zck"
PROXY_LIST_FILE="$STATE_DIR/proxies.json"
ACTIVE_PROXY_FILE="$STATE_DIR/active_proxy"

BYPASS_NFT="$STATE_DIR/bypass.nft"
BYPASS_APPLY="/usr/local/sbin/egress-bypass-apply"
BYPASS_REMOVE="/usr/local/sbin/egress-bypass-remove"
BYPASS_UNIT="/etc/systemd/system/egress-bypass.service"
CHECK_BIN="/usr/local/sbin/egress-socks-check"
CHECK_UNIT="/etc/systemd/system/egress-socks-check.service"
CHECK_TIMER="/etc/systemd/system/egress-socks-check.timer"
REPORT_ENV_FILE="$STATE_DIR/report.env"
NOTIFY_BIN="/usr/local/sbin/egress-socks-notify"
REPORT_UNIT="/etc/systemd/system/egress-socks-report.service"
REPORT_TIMER="/etc/systemd/system/egress-socks-report.timer"
MODE_FILE="$STATE_DIR/mode"
ROLLBACK_SENTINEL="/run/egress-socks-start-ok"
ROLLBACK_SCRIPT="/run/egress-socks-rollback.sh"

# Legacy artefacts from previous installs.
LEGACY_TUN_NAMES=(incusse-tun0)
LEGACY_NFT_TABLES=(
  'ip proxy_nat'
  'ip6 proxy6_guard'
  'inet egress_socks_guard'
  'ip egress_socks_incus'
  'inet sing-box'
  'ip sing-box'
  'ip6 sing-box'
)

# -----------------------------------------------------------------------------
# Sanity checks.
# -----------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 root 运行：sudo $0"
  exit 1
fi
if ! command -v apt-get >/dev/null 2>&1; then
  echo "此脚本只面向 Debian/Ubuntu 节点。"
  exit 1
fi

log() { printf '\n=== %s ===\n' "$*"; }

shell_quote() {
  printf '%q' "$1"
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

validate_inputs() {
  local name value
  for name in NODE_SSH_PORT INCUS_API_PORT PORT_RANGE_LOW PORT_RANGE_HIGH; do
    value="${!name}"
    if ! valid_port "$value"; then
      echo "配置错误：$name 不是合法端口：$value" >&2
      exit 1
    fi
  done
  if [[ -n "$BUILTIN_PROXY_PORT" ]] && ! valid_port "$BUILTIN_PROXY_PORT"; then
    echo "配置错误：BUILTIN_PROXY_PORT 不是合法端口：$BUILTIN_PROXY_PORT" >&2
    exit 1
  fi
  if (( PORT_RANGE_LOW > PORT_RANGE_HIGH )); then
    echo "配置错误：PORT_RANGE_LOW 不能大于 PORT_RANGE_HIGH" >&2
    exit 1
  fi
  if [[ -z "$TUN_NAME" || -z "$INCUS_BRIDGE" || -z "$INCUS_SUBNET" || -z "$BOOTSTRAP_DNS" ]]; then
    echo "配置错误：TUN_NAME / INCUS_BRIDGE / INCUS_SUBNET / BOOTSTRAP_DNS 不能为空" >&2
    exit 1
  fi
  if [[ "$TUN_IPV6" != "0" && "$TUN_IPV6" != "1" ]]; then
    echo "配置错误：TUN_IPV6 只能是 0 或 1" >&2
    exit 1
  fi
}

configure_report_settings() {
  if [[ -z "$REPORT_NODE_NAME" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "节点名称 [$(hostname -s 2>/dev/null || hostname)]: " REPORT_NODE_NAME
    fi
  fi
  REPORT_NODE_NAME="${REPORT_NODE_NAME:-$(hostname -s 2>/dev/null || hostname)}"

  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  cat > "$REPORT_ENV_FILE" <<EOF
REPORT_NODE_NAME=$(shell_quote "$REPORT_NODE_NAME")
TG_BOT_TOKEN=$(shell_quote "$TG_BOT_TOKEN")
TG_CHAT_ID=$(shell_quote "$TG_CHAT_ID")
EOF
  chmod 600 "$REPORT_ENV_FILE"
}

# =============================================================================
# 1. Cleanup
# =============================================================================
cleanup_all() {
  log "[1/6] 清理旧规则与服务"

  systemctl disable --now sing-box        >/dev/null 2>&1 || true
  systemctl disable --now egress-bypass   >/dev/null 2>&1 || true
  systemctl disable --now egress-socks-report.timer >/dev/null 2>&1 || true
  systemctl disable --now redsocks        >/dev/null 2>&1 || true
  systemctl disable --now egress-socks-nft.service >/dev/null 2>&1 || true

  # Old/new nft tables (best-effort).
  local t
  for t in "${LEGACY_NFT_TABLES[@]}" 'inet egress-bypass'; do
    # shellcheck disable=SC2086
    nft delete table $t 2>/dev/null || true
  done

  # Old-style files.
  rm -f /etc/nftables.d/egress-socks-incus.nft
  rm -f /etc/systemd/system/egress-socks-nft.service
  rm -f /etc/systemd/system/sing-box.service.d/10-bypass.conf
  rmdir /etc/systemd/system/sing-box.service.d 2>/dev/null || true
  rm -f /usr/local/sbin/apply-egress-socks-nft
  rm -f /etc/systemd/system/nftables.service.d/after-singbox.conf
  rmdir /etc/systemd/system/nftables.service.d 2>/dev/null || true

  # Bypass policy rules from any previous install.
  local fam
  for fam in -4 -6; do
    while ip $fam rule show 2>/dev/null | grep -qE "fwmark $BYPASS_MARK_HEX"; do
      ip $fam rule del fwmark "$BYPASS_MARK_HEX" 2>/dev/null || break
    done
  done

  # sing-box's own policy rules + custom table.
  local pref
  for fam in -4 -6; do
    while ip $fam rule show 2>/dev/null | grep -qE "lookup (sing-box|$SINGBOX_TABLE_INDEX)"; do
      pref=$(ip $fam rule show 2>/dev/null \
              | awk -F: "/lookup (sing-box|$SINGBOX_TABLE_INDEX)/ \
                         {gsub(/[ \\t]+/,\"\",\$1); print \$1; exit}")
      [[ -z "$pref" ]] && break
      ip $fam rule del pref "$pref" 2>/dev/null || break
    done
    ip $fam route flush table "$SINGBOX_TABLE_INDEX" 2>/dev/null || true
    ip $fam route flush table sing-box                2>/dev/null || true
  done

  # Tear down any stale TUN devices (new and legacy names).
  ip link delete "$TUN_NAME" 2>/dev/null || true
  for t in "${LEGACY_TUN_NAMES[@]}"; do
    ip link delete "$t" 2>/dev/null || true
  done

  # Drop old fwmark-based egress rules from the very first iteration.
  if command -v iptables-save >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1; then
    local rule
    iptables-save -t mangle 2>/dev/null \
      | awk '$1=="-A" && ($0 ~ /0xca6c/ || $0 ~ /51820/) {sub(/^-A /,"-D "); print}' \
      | while IFS= read -r rule; do
          # shellcheck disable=SC2086
          iptables -t mangle $rule >/dev/null 2>&1 || true
        done
  fi

  rm -f "$BYPASS_NFT" "$BYPASS_APPLY" "$BYPASS_REMOVE" "$BYPASS_UNIT"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

# =============================================================================
# 2. Install sing-box
# =============================================================================
install_packages() {
  log "[2/6] 安装 sing-box / 工具链"
  apt-get update -qq
  apt-get install -y -qq \
    ca-certificates curl gpg nftables iproute2 python3 \
    netcat-openbsd jq

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

# =============================================================================
# 3. Generate sing-box config
# =============================================================================
resolve_ipv4() {
  local host="$1"
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "$host"
    return
  fi
  getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}'
}

ensure_proxy_store() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  local raw="${BUILTIN_PROXY_URL:-}"
  if [[ -z "$raw" && -n "$BUILTIN_PROXY_HOST" && -n "$BUILTIN_PROXY_PORT" && -n "$BUILTIN_PROXY_USER" && -n "$BUILTIN_PROXY_PASS" ]]; then
    raw="socks5://${BUILTIN_PROXY_USER}:${BUILTIN_PROXY_PASS}@${BUILTIN_PROXY_HOST}:${BUILTIN_PROXY_PORT}"
  fi

  # Explicit proxy input on install should override stale state from a
  # previous run. Without this, rerunning with BUILTIN_PROXY_URL keeps testing
  # the old /etc/egress-socks/proxies.json entry.
  if [[ -n "$raw" || ! -s "$PROXY_LIST_FILE" ]]; then
    if [[ -z "$raw" ]]; then
      if [[ ! -t 0 ]]; then
        echo "未配置上游代理。请用 BUILTIN_PROXY_URL='socks5://用户名:密码@地址:端口' 或 'ss://加密:密码@地址:端口' 运行，或交互式执行脚本。" >&2
        exit 1
      fi
      echo "未检测到上游代理，首次安装需要输入家宽端输出的地址。"
      read -r -p "请输入代理地址 (socks5://用户名:密码@地址:端口 或 ss://加密:密码@地址:端口): " raw
    fi
    PROXY_LIST_FILE="$PROXY_LIST_FILE" \
    RAW_PROXY="$raw" \
    python3 - <<'PY'
import json
import os
import base64
import urllib.parse

path = os.environ["PROXY_LIST_FILE"]
raw = os.environ["RAW_PROXY"].strip().replace("：", ":")
if raw.startswith("ssocks5://"):
    raw = "socks5://" + raw[len("ssocks5://"):]
if "://" not in raw:
    raw = "socks5://" + raw
url = urllib.parse.urlparse(raw)
if url.scheme not in ("socks5", "ss"):
    raise SystemExit("只支持 socks5:// 或 ss://")
if not url.hostname or not url.port:
    raise SystemExit("格式错误，应为 socks5://用户名:密码@地址:端口 或 ss://加密:密码@地址:端口")
if url.scheme == "socks5" and (url.username is None) != (url.password is None):
    raise SystemExit("SOCKS5 格式错误，账号密码要么都填(socks5://用户名:密码@地址:端口)，要么都不填(socks5://地址:端口，用于无认证隧道)")
if url.scheme == "ss":
    method = urllib.parse.unquote(url.username or "")
    password = urllib.parse.unquote(url.password or "")
    if not method or not password:
        userinfo = urllib.parse.unquote((url.netloc.rsplit("@", 1)[0] if "@" in url.netloc else ""))
        padded = userinfo + "=" * (-len(userinfo) % 4)
        try:
            decoded = base64.urlsafe_b64decode(padded.encode()).decode()
        except Exception:
            decoded = ""
        if ":" in decoded:
            method, password = decoded.split(":", 1)
    if not method or not password:
        raise SystemExit("SS 格式错误，应为 ss://加密:密码@地址:端口")
item = {
    "name": "builtin",
    "type": "shadowsocks" if url.scheme == "ss" else "socks5",
    "host": url.hostname,
    "port": int(url.port),
    "username": urllib.parse.unquote(url.username or "") if url.scheme == "socks5" else "",
    "password": urllib.parse.unquote(url.password or "") if url.scheme == "socks5" else password,
    "method": method if url.scheme == "ss" else "",
}
with open(path, "w", encoding="utf-8") as f:
    json.dump([item], f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
    chmod 600 "$PROXY_LIST_FILE"
    printf '0\n' > "$ACTIVE_PROXY_FILE"
    chmod 600 "$ACTIVE_PROXY_FILE"
  fi

  if [[ ! -s "$ACTIVE_PROXY_FILE" ]]; then
    printf '0\n' > "$ACTIVE_PROXY_FILE"
    chmod 600 "$ACTIVE_PROXY_FILE"
  fi
}

active_proxy_url() {
  load_active_proxy
  if [[ "${ACTIVE_PROXY_TYPE:-socks5}" != "socks5" ]]; then
    return 1
  fi
  ACTIVE_PROXY_HOST="$ACTIVE_PROXY_HOST" \
  ACTIVE_PROXY_PORT="$ACTIVE_PROXY_PORT" \
  ACTIVE_PROXY_USER="$ACTIVE_PROXY_USER" \
  ACTIVE_PROXY_PASS="$ACTIVE_PROXY_PASS" \
  python3 - <<'PY'
import os
import urllib.parse

user = urllib.parse.quote(os.environ["ACTIVE_PROXY_USER"], safe="")
password = urllib.parse.quote(os.environ["ACTIVE_PROXY_PASS"], safe="")
host = os.environ["ACTIVE_PROXY_HOST"]
port = os.environ["ACTIVE_PROXY_PORT"]
# Unauthenticated SOCKS5 (SSH -D tunnel): emit socks5://host:port without an
# empty "user:pass@", which curl would otherwise treat as a literal credential.
if user or password:
    print(f"socks5://{user}:{password}@{host}:{port}")
else:
    print(f"socks5://{host}:{port}")
PY
}

test_active_proxy_direct() {
  local proxy_url out
  if [[ "${ACTIVE_PROXY_TYPE:-socks5}" != "socks5" ]]; then
    echo "  上游 SS 将由 sing-box 校验并连接，跳过 curl SOCKS5 测试。"
    return 0
  fi
  proxy_url="$(active_proxy_url)"
  out="$(curl -4 --connect-timeout "$EGRESS_CONNECT_TIMEOUT" --max-time "$EGRESS_MAX_TIME" --retry "$EGRESS_RETRIES" --retry-delay 2 -fsS --proxy "$proxy_url" "$EGRESS_PROBE_URL" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ ! "$out" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "  [WARN] 上游 SOCKS5 出口 IP 测试失败，可能是测速站被重置/拦截。" >&2
    echo "         将继续生成配置；如需测试失败就退出，请加 STRICT_PROXY_TEST=1。" >&2
    if [[ "${STRICT_PROXY_TEST:-0}" == "1" ]]; then
      echo "上游 SOCKS5 真实连通性测试失败，请确认地址、端口、账号密码和家宽防火墙。" >&2
      return 1
    fi
    return 0
  fi
  echo "  上游 SOCKS5 测试通过，代理出口 IP: $out"
}

curl_egress_ip() {
  local out
  out="$(curl -4 --connect-timeout "$EGRESS_CONNECT_TIMEOUT" --max-time "$EGRESS_MAX_TIME" --retry "$EGRESS_RETRIES" --retry-delay 2 -fsS "$EGRESS_PROBE_URL" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$out" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  echo "$out"
}

load_active_proxy() {
  ensure_proxy_store
  eval "$(
    PROXY_LIST_FILE="$PROXY_LIST_FILE" ACTIVE_PROXY_FILE="$ACTIVE_PROXY_FILE" python3 - <<'PY'
import json
import os
import shlex

with open(os.environ["PROXY_LIST_FILE"], "r", encoding="utf-8") as f:
    items = json.load(f)
if not isinstance(items, list) or not items:
    raise SystemExit("上游出口列表为空")
try:
    idx = int(open(os.environ["ACTIVE_PROXY_FILE"], "r", encoding="utf-8").read().strip() or "0")
except Exception:
    idx = 0
if idx < 0 or idx >= len(items):
    idx = 0
item = items[idx]
for key, value in {
    "ACTIVE_PROXY_INDEX": str(idx),
    "ACTIVE_PROXY_TYPE": str(item.get("type", "socks5")),
    "ACTIVE_PROXY_HOST": str(item["host"]),
    "ACTIVE_PROXY_PORT": str(item["port"]),
    "ACTIVE_PROXY_USER": str(item.get("username", "")),
    "ACTIVE_PROXY_PASS": str(item.get("password", "")),
    "ACTIVE_PROXY_METHOD": str(item.get("method", "")),
}.items():
    print(f"{key}={shlex.quote(value)}")
PY
  )"
}

write_singbox_config() {
  log "[3/6] 生成 sing-box 配置"
  mkdir -p "$CONFIG_DIR" "$STATE_DIR"
  chmod 700 "$CONFIG_DIR" "$STATE_DIR"

  load_active_proxy

  local proxy_ip
  proxy_ip="$(resolve_ipv4 "$ACTIVE_PROXY_HOST")"
  if [[ -z "$proxy_ip" ]]; then
    echo "无法解析上游服务器 IPv4：$ACTIVE_PROXY_HOST" >&2
    exit 1
  fi

  if [[ "${ACTIVE_PROXY_TYPE:-socks5}" == "shadowsocks" ]]; then
    echo "  上游 SS #$((ACTIVE_PROXY_INDEX + 1)): ${ACTIVE_PROXY_METHOD}@${proxy_ip}:$ACTIVE_PROXY_PORT"
  else
    echo "  上游 SOCKS5 #$((ACTIVE_PROXY_INDEX + 1)): ${ACTIVE_PROXY_USER:+$ACTIVE_PROXY_USER@}$proxy_ip:$ACTIVE_PROXY_PORT"
  fi
  test_active_proxy_direct

  python3 - \
    "$CONFIG_FILE" "$proxy_ip" "$ACTIVE_PROXY_PORT" \
    "$ACTIVE_PROXY_USER" "$ACTIVE_PROXY_PASS" "$ACTIVE_PROXY_TYPE" "$ACTIVE_PROXY_METHOD" \
    "$TUN_NAME" "$TUN_ADDR4" "$TUN_ADDR6" "$INCUS_SUBNET" \
    "$SINGBOX_TABLE_INDEX" "$SINGBOX_RULE_INDEX" "$BOOTSTRAP_DNS" "$TUN_IPV6" \
<<'PY'
import json
import sys

(_, cfg_path, proxy_ip, proxy_port, proxy_user, proxy_pass, proxy_type, proxy_method,
 tun_name, tun_addr4, tun_addr6, incus_subnet, table_idx, rule_idx,
 bootstrap_dns, tun_ipv6) = sys.argv

enable_ipv6 = tun_ipv6 == "1"
tun_addresses = [tun_addr4]
if enable_ipv6:
    tun_addresses.append(tun_addr6)
excluded_cidrs = [
    "127.0.0.0/8",
    "169.254.0.0/16",
    "224.0.0.0/4",
    "240.0.0.0/4",
    incus_subnet,
]
if enable_ipv6:
    excluded_cidrs.extend(["::1/128", "fe80::/10", "ff00::/8"])

if proxy_type == "shadowsocks":
    proxy_outbound = {
        "type": "shadowsocks",
        "tag": "proxy",
        "server": proxy_ip,
        "server_port": int(proxy_port),
        "method": proxy_method,
        "password": proxy_pass,
    }
else:
    proxy_outbound = {
        "type": "socks",
        "tag": "proxy",
        "server": proxy_ip,
        "server_port": int(proxy_port),
        "version": "5",
    }
    # Omit credentials entirely for unauthenticated SOCKS5 (e.g. an SSH `-D`
    # dynamic tunnel), which has no username/password. Sending empty strings
    # would make sing-box attempt user/pass auth and fail.
    if proxy_user or proxy_pass:
        proxy_outbound["username"] = proxy_user
        proxy_outbound["password"] = proxy_pass

cfg = {
    "log": {"level": "info", "timestamp": True},
    "dns": {
        "servers": [
            # Bootstrap resolver: never goes through the proxy. Used for
            # direct destinations (panel, SOCKS server itself, Incus
            # subnet) and as default_domain_resolver for every outbound.
            {
                "type": "udp",
                "tag": "local-dns",
                "server": bootstrap_dns,
                "detour": "direct",
            },
        ],
        "final": "local-dns",
        "strategy": "ipv4_only",
    },
    "inbounds": [
        {
            "type": "tun",
            "tag": "tun-in",
            "interface_name": tun_name,
            "address": tun_addresses,
            "mtu": 1500,
            "auto_route": True,
            "iproute2_table_index": int(table_idx),
            "iproute2_rule_index":  int(rule_idx),
            "strict_route": False,
            "stack": "system",
            # Don't claim routes for these — let the kernel keep using the
            # original connected / loopback routes. Crucially this includes
            # the Incus bridge subnet so host↔guest stays on incusbr0.
            "route_exclude_address": excluded_cidrs,
        }
    ],
    "outbounds": [
        proxy_outbound,
        # `direct` must carry at least one explicit option so sing-box 1.13
        # accepts `detour: "direct"` on local-dns above.
        {
            "type": "direct",
            "tag": "direct",
            "domain_resolver": "local-dns",
        },
        {
            "type": "block",
            "tag": "block",
        },
    ],
    "route": {
        "auto_detect_interface": True,
        "default_domain_resolver": {
            "server": "local-dns",
            "strategy": "ipv4_only",
        },
        "rules": [
            # Answer all DNS via the DNS module above. Match by port as well
            # as protocol because packets to the TUN synthetic DNS address
            # are not always parsed as "protocol=dns" before route matching.
            {"protocol": "dns", "action": "hijack-dns"},
            {"port": 53, "action": "hijack-dns"},
            # Belt-and-braces — `route_exclude_address` should keep these
            # off TUN anyway, but if anything slips through, route it via
            # direct rather than the proxy.
            {
                "ip_cidr": [
                    *excluded_cidrs,
                    f"{proxy_ip}/32",
                ],
                "action": "route",
                "outbound": "direct",
            },
        ],
        "final": "proxy",
    },
}

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
  chmod 600 "$CONFIG_FILE"
}

# =============================================================================
# 4. Install bypass nft + systemd unit
# =============================================================================
write_bypass_unit() {
  log "[4/6] 生成回流绕过规则 (egress-bypass)"

  cat > "$BYPASS_NFT" <<NFT
#!/usr/sbin/nft -f
# Mark return-path packets so they bypass sing-box's TUN routing.
#
# Without this, host services that answer inbound clients (sshd, Incus
# API, conntrack-reversed port-forwarding replies) would have their reply
# packets diverted into the TUN and re-dialled via the proxy as a brand
# new connection — which the original peer would drop, killing SSH,
# panel access, and every user-forwarded port.

table inet egress-bypass {
  chain output {
    # Local packets need a route hook, not a filter hook: changing meta mark
    # in a filter/output chain may be too late to trigger a new route lookup.
    # The route/output hook makes SSH/API replies immediately hit the fwmark
    # rule below before sing-box's TUN rule can catch them.
    type route hook output priority mangle; policy accept;
    ct mark ${BYPASS_MARK_HEX} meta mark set ${BYPASS_MARK_HEX}
    meta l4proto tcp tcp sport { ${NODE_SSH_PORT}, ${INCUS_API_PORT} } meta mark set ${BYPASS_MARK_HEX}
    meta l4proto tcp tcp sport ${PORT_RANGE_LOW}-${PORT_RANGE_HIGH} meta mark set ${BYPASS_MARK_HEX}
    meta l4proto udp udp sport ${PORT_RANGE_LOW}-${PORT_RANGE_HIGH} meta mark set ${BYPASS_MARK_HEX}
  }

  chain prerouting {
    # Use conntrack mark instead of guessing reply source ports. On a
    # DNATed port-forward flow, the reply from a guest usually enters the
    # host with the guest's real source port (e.g. 22), not the public
    # mapped port. Mark every NEW connection that enters from outside the
    # Incus bridge/TUN, then restore that mark on all packets in the flow.
    # This keeps SSH/API/user-forward replies on the original route even
    # when the public forwarding port is outside PORT_RANGE_LOW/HIGH.
    type filter hook prerouting priority mangle; policy accept;

    ct mark ${BYPASS_MARK_HEX} meta mark set ${BYPASS_MARK_HEX}

    iifname != "${INCUS_BRIDGE}" iifname != "${TUN_NAME}" ct state new ct mark set ${BYPASS_MARK_HEX} meta mark set ${BYPASS_MARK_HEX}

    iifname != "${INCUS_BRIDGE}" meta l4proto tcp tcp dport { ${NODE_SSH_PORT}, ${INCUS_API_PORT} } ct mark set ${BYPASS_MARK_HEX} meta mark set ${BYPASS_MARK_HEX}
    iifname != "${INCUS_BRIDGE}" meta l4proto tcp tcp dport ${PORT_RANGE_LOW}-${PORT_RANGE_HIGH} ct mark set ${BYPASS_MARK_HEX} meta mark set ${BYPASS_MARK_HEX}
    iifname != "${INCUS_BRIDGE}" meta l4proto udp udp dport ${PORT_RANGE_LOW}-${PORT_RANGE_HIGH} ct mark set ${BYPASS_MARK_HEX} meta mark set ${BYPASS_MARK_HEX}
  }
}
NFT

  cat > "$BYPASS_APPLY" <<APPLY
#!/usr/bin/env bash
set -e
# Replace the table atomically (delete + add), without touching other
# nft tables (notably Incus's).
/usr/sbin/nft delete table inet egress-bypass 2>/dev/null || true
/usr/sbin/nft -f $BYPASS_NFT

# Marked packets bypass sing-box's TUN routing table by looking up main
# instead. pref ${BYPASS_RULE_PREF} < sing-box's pref ${SINGBOX_RULE_INDEX},
# so this rule wins for marked packets while everything else falls
# through to TUN.
ip -4 rule add fwmark ${BYPASS_MARK_HEX} lookup main pref ${BYPASS_RULE_PREF} 2>/dev/null || true
ip -6 rule add fwmark ${BYPASS_MARK_HEX} lookup main pref ${BYPASS_RULE_PREF} 2>/dev/null || true
APPLY
  chmod +x "$BYPASS_APPLY"

  cat > "$BYPASS_REMOVE" <<REMOVE
#!/usr/bin/env bash
nft delete table inet egress-bypass 2>/dev/null || true
ip -4 rule del fwmark ${BYPASS_MARK_HEX} lookup main pref ${BYPASS_RULE_PREF} 2>/dev/null || true
ip -6 rule del fwmark ${BYPASS_MARK_HEX} lookup main pref ${BYPASS_RULE_PREF} 2>/dev/null || true
REMOVE
  chmod +x "$BYPASS_REMOVE"

  cat > "$BYPASS_UNIT" <<UNIT
[Unit]
Description=Egress bypass marks for sing-box return paths
After=network-online.target nftables.service
Before=sing-box.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BYPASS_APPLY
ExecStop=$BYPASS_REMOVE

[Install]
WantedBy=multi-user.target
UNIT

  # Hard-couple sing-box to egress-bypass so that on every start (including
  # boot and `systemctl restart sing-box`) the kernel-side bypass is fully
  # in place BEFORE the TUN starts grabbing host traffic.
  mkdir -p /etc/systemd/system/sing-box.service.d
  cat > /etc/systemd/system/sing-box.service.d/10-bypass.conf <<UNIT
[Unit]
Requires=egress-bypass.service
After=egress-bypass.service
UNIT

  systemctl daemon-reload
  systemctl enable egress-bypass.service >/dev/null 2>&1 || true
}

# =============================================================================
# 5. Install zck helper
# =============================================================================
schedule_rollback_guard() {
  rm -f "$ROLLBACK_SENTINEL"
  cat > "$ROLLBACK_SCRIPT" <<'ROLLBACK'
#!/usr/bin/env bash
set -euo pipefail
sleep 90
if [[ ! -e /run/egress-socks-start-ok ]]; then
  systemctl disable --now sing-box >/dev/null 2>&1 || true
  systemctl disable --now egress-bypass >/dev/null 2>&1 || true
  ip link delete egress-tun0 >/dev/null 2>&1 || true
  nft delete table inet egress-bypass >/dev/null 2>&1 || true
  ip -4 rule del fwmark 0x42 lookup main pref 8000 >/dev/null 2>&1 || true
  ip -6 rule del fwmark 0x42 lookup main pref 8000 >/dev/null 2>&1 || true
fi
ROLLBACK
  chmod +x "$ROLLBACK_SCRIPT"

  if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --unit=egress-socks-rollback --collect "$ROLLBACK_SCRIPT" >/dev/null 2>&1 || true
  else
    nohup "$ROLLBACK_SCRIPT" >/dev/null 2>&1 &
  fi
  echo "  已设置 90 秒自动回滚保险；若 SSH 再断，会自动关闭 sing-box 恢复直连。"
}

install_helper() {
  log "[5/6] 安装 zck 管理命令"
  cat > "$HELPER_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/sing-box/config.json"
BYPASS_MARK="0x42"
PROXY_LIST_FILE="/etc/egress-socks/proxies.json"
ACTIVE_PROXY_FILE="/etc/egress-socks/active_proxy"
MODE_FILE="/etc/egress-socks/mode"
EGRESS_PROBE_URL="${EGRESS_PROBE_URL:-https://ip.sb}"
EGRESS_CONNECT_TIMEOUT="${EGRESS_CONNECT_TIMEOUT:-12}"
EGRESS_MAX_TIME="${EGRESS_MAX_TIME:-35}"
EGRESS_RETRIES="${EGRESS_RETRIES:-2}"

TUN_NAME="$(python3 - 2>/dev/null <<'PY' || echo egress-tun0
import json
try:
    with open("/etc/sing-box/config.json") as f:
        cfg = json.load(f)
    for ib in cfg.get("inbounds", []):
        if ib.get("type") == "tun":
            print(ib.get("interface_name", "egress-tun0")); break
except Exception:
    print("egress-tun0")
PY
)"

curl_egress_ip() {
  local out
  out="$(curl -4 --connect-timeout "$EGRESS_CONNECT_TIMEOUT" --max-time "$EGRESS_MAX_TIME" --retry "$EGRESS_RETRIES" --retry-delay 2 -fsS "$EGRESS_PROBE_URL" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$out" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  echo "$out"
}

usage() {
  cat <<USAGE
用法: sudo zck <command>
  status    sing-box / egress-bypass / TUN 状态
  test      节点 + 第一个 Incus 小鸡 的代理出口测试
  diag      详细诊断（路由、规则、nft、上游 TCP 连通性）
  proxy     管理上游出口：list | add socks5://用户名:密码@ip:端口 或 ss://加密:密码@ip:端口 | switch | delete
  logs      tail sing-box journal
  check     校验 sing-box 配置
  restart   重启 sing-box（保留 bypass）
  repair    自修复检查并补齐 sing-box / bypass / TUN
  fallback  回落本机原出口，但保留定时器后续自动尝试恢复
  recover   立即尝试恢复到家宽 SOCKS/SS 出口
  off       停掉 sing-box、egress-bypass 与自修复，恢复直连
  on        重新启用 sing-box、egress-bypass 与自修复
USAGE
}

ensure_proxy_store() {
  mkdir -p /etc/egress-socks
  chmod 700 /etc/egress-socks
  if [[ ! -s "$PROXY_LIST_FILE" ]]; then
    python3 - <<'PY'
import json
with open("/etc/egress-socks/proxies.json", "w", encoding="utf-8") as f:
    json.dump([], f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
    chmod 600 "$PROXY_LIST_FILE"
  fi
  if [[ ! -s "$ACTIVE_PROXY_FILE" ]]; then
    printf '0\n' > "$ACTIVE_PROXY_FILE"
    chmod 600 "$ACTIVE_PROXY_FILE"
  fi
}

proxy_list() {
  ensure_proxy_store
  PROXY_LIST_FILE="$PROXY_LIST_FILE" ACTIVE_PROXY_FILE="$ACTIVE_PROXY_FILE" python3 - <<'PY'
import json
import os

with open(os.environ["PROXY_LIST_FILE"], "r", encoding="utf-8") as f:
    items = json.load(f)
if not items:
    print("上游出口列表为空，请先执行: sudo zck proxy add socks5://用户名:密码@地址:端口 或 ss://加密:密码@地址:端口")
    raise SystemExit(0)
try:
    active = int(open(os.environ["ACTIVE_PROXY_FILE"], "r", encoding="utf-8").read().strip() or "0")
except Exception:
    active = 0
for i, item in enumerate(items, 1):
    mark = "*" if i - 1 == active else " "
    typ = item.get("type", "socks5")
    user = item.get("username") or item.get("method") or ""
    auth = f"{user}@" if user else ""
    name = item.get("name") or f"proxy-{i}"
    print(f"{mark} {i}. [{typ}] {name}  {auth}{item['host']}:{item['port']}")
PY
}

proxy_add() {
  ensure_proxy_store
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    read -r -p "请输入代理（socks5://用户名:密码@ip:端口 或 ss://加密:密码@ip:端口）: " raw
  fi
  PROXY_LIST_FILE="$PROXY_LIST_FILE" RAW_PROXY="$raw" python3 - <<'PY'
import base64
import json
import os
import socket
import urllib.parse

path = os.environ["PROXY_LIST_FILE"]
raw = os.environ["RAW_PROXY"].strip().replace("：", ":")
if raw.startswith("ssocks5://"):
    raw = "socks5://" + raw[len("ssocks5://"):]
if "://" not in raw:
    raw = "socks5://" + raw
url = urllib.parse.urlparse(raw)
if url.scheme not in ("socks5", "ss"):
    raise SystemExit("只支持 socks5:// 或 ss://")
if not url.hostname or not url.port:
    raise SystemExit("格式错误，应为 socks5://用户名:密码@ip:端口 或 ss://加密:密码@ip:端口")
method = ""
password = ""
username = ""
if url.scheme == "socks5":
    if (url.username is None) != (url.password is None):
        raise SystemExit("SOCKS5 格式错误，账号密码要么都填(socks5://用户名:密码@ip:端口)，要么都不填(socks5://ip:端口，用于无认证隧道)")
    username = urllib.parse.unquote(url.username) if url.username is not None else ""
    password = urllib.parse.unquote(url.password) if url.password is not None else ""
else:
    method = urllib.parse.unquote(url.username or "")
    password = urllib.parse.unquote(url.password or "")
    if not method or not password:
        userinfo = urllib.parse.unquote((url.netloc.rsplit("@", 1)[0] if "@" in url.netloc else ""))
        padded = userinfo + "=" * (-len(userinfo) % 4)
        try:
            decoded = base64.urlsafe_b64decode(padded.encode()).decode()
        except Exception:
            decoded = ""
        if ":" in decoded:
            method, password = decoded.split(":", 1)
    if not method or not password:
        raise SystemExit("SS 格式错误，应为 ss://加密:密码@ip:端口")
try:
    socket.getaddrinfo(url.hostname, url.port, socket.AF_INET, socket.SOCK_STREAM)
except socket.gaierror as exc:
    raise SystemExit(f"无法解析/验证 IPv4：{url.hostname}: {exc}") from exc
try:
    with socket.create_connection((url.hostname, url.port), timeout=5):
        pass
except OSError as exc:
    raise SystemExit(f"上游 TCP 端口不可达：{url.hostname}:{url.port} ({exc})") from exc

item = {
    "name": f"{url.hostname}:{url.port}",
    "type": "shadowsocks" if url.scheme == "ss" else "socks5",
    "host": url.hostname,
    "port": int(url.port),
    "username": username,
    "password": password,
    "method": method,
}
with open(path, "r", encoding="utf-8") as f:
    items = json.load(f)
for old in items:
    if (old.get("type", "socks5"), old.get("host"), int(old.get("port", 0)), old.get("username", ""), old.get("password", ""), old.get("method", "")) == (
        item["type"], item["host"], item["port"], item["username"], item["password"], item["method"]
    ):
        print("已存在，未重复添加。")
        break
else:
    items.append(item)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=2)
        f.write("\n")
    label = item["username"] or item["method"]
    prefix = f"{label}@" if label else ""
    print(f"已添加：#{len(items)} [{item['type']}] {prefix}{item['host']}:{item['port']}")
PY
  chmod 600 "$PROXY_LIST_FILE"
}

active_one_based() {
  ensure_proxy_store
  python3 - <<'PY'
try:
    active = int(open("/etc/egress-socks/active_proxy", "r", encoding="utf-8").read().strip() or "0")
except Exception:
    active = 0
print(active + 1)
PY
}

test_current_egress() {
  local out
  if ! out="$(curl_egress_ip)"; then
    echo "出口测试失败"
    return 1
  fi
  echo "出口 IP: $out"
}

switch_with_rollback() {
  local n="$1"
  local old
  old="$(active_one_based)"
  proxy_apply_index "$n"
  sing-box check -c "$CONFIG_FILE"
  if systemctl --quiet is-active sing-box; then
    systemctl restart sing-box
    sleep 2
    if test_current_egress; then
      echo "sing-box 已重启，当前出口已切换。"
    else
      echo "新上游出口不可用，回滚到 #$old ..."
      proxy_apply_index "$old"
      sing-box check -c "$CONFIG_FILE"
      systemctl restart sing-box
      return 1
    fi
  else
    echo "sing-box 当前未运行；配置已更新，下次启动生效。"
  fi
}

proxy_apply_index() {
  ensure_proxy_store
  local one_based="$1"
  PROXY_LIST_FILE="$PROXY_LIST_FILE" ACTIVE_PROXY_FILE="$ACTIVE_PROXY_FILE" CONFIG_FILE="$CONFIG_FILE" ONE_BASED="$one_based" python3 - <<'PY'
import json
import os
import socket

proxy_path = os.environ["PROXY_LIST_FILE"]
active_path = os.environ["ACTIVE_PROXY_FILE"]
cfg_path = os.environ["CONFIG_FILE"]
idx = int(os.environ["ONE_BASED"]) - 1

with open(proxy_path, "r", encoding="utf-8") as f:
    items = json.load(f)
if idx < 0 or idx >= len(items):
    raise SystemExit("序号无效")
item = items[idx]
resolved = socket.getaddrinfo(item["host"], int(item["port"]), socket.AF_INET, socket.SOCK_STREAM)[0][4][0]

with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

old_proxy_ips = set()
for outbound in cfg.get("outbounds", []):
    if outbound.get("tag") == "proxy":
        if outbound.get("server"):
            old_proxy_ips.add(str(outbound["server"]) + "/32")
        outbound.clear()
        if item.get("type", "socks5") == "shadowsocks":
            outbound.update({
                "type": "shadowsocks",
                "tag": "proxy",
                "server": resolved,
                "server_port": int(item["port"]),
                "method": item.get("method", ""),
                "password": item.get("password", ""),
            })
        else:
            outbound.update({
                "type": "socks",
                "tag": "proxy",
                "server": resolved,
                "server_port": int(item["port"]),
                "version": "5",
                "username": item.get("username", ""),
                "password": item.get("password", ""),
            })

for old in items:
    try:
        old_ip = socket.getaddrinfo(old["host"], int(old["port"]), socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
        old_proxy_ips.add(old_ip + "/32")
    except Exception:
        pass

new_proxy_cidr = resolved + "/32"
rules = cfg.get("route", {}).get("rules", [])
for rule in rules:
    if rule.get("action") == "route" and rule.get("outbound") == "direct" and isinstance(rule.get("ip_cidr"), list):
        cidrs = [c for c in rule["ip_cidr"] if c not in old_proxy_ips]
        if new_proxy_cidr not in cidrs:
            cidrs.append(new_proxy_cidr)
        rule["ip_cidr"] = cidrs
        break

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
with open(active_path, "w", encoding="utf-8") as f:
    f.write(str(idx) + "\n")

label = item.get("username") or item.get("method") or item.get("type", "proxy")
print(f"已切换到 #{idx + 1}: [{item.get('type','socks5')}] {label}@{resolved}:{item['port']}")
PY
  chmod 600 "$ACTIVE_PROXY_FILE" "$CONFIG_FILE"
}

proxy_switch() {
  ensure_proxy_store
  proxy_list
  local n
  read -r -p "输入要切换的序号: " n
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "序号无效"
    return 1
  fi
  switch_with_rollback "$n"
}

proxy_delete() {
  ensure_proxy_store
  local n="${1:-}"
  if [[ -z "$n" ]]; then
    proxy_list
    read -r -p "输入要删除的序号: " n
  fi
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "序号无效"
    return 1
  fi

  local result deleted_active new_active deleted_desc
  result="$(
    PROXY_LIST_FILE="$PROXY_LIST_FILE" ACTIVE_PROXY_FILE="$ACTIVE_PROXY_FILE" ONE_BASED="$n" python3 - <<'PY'
import json
import os
import shlex

proxy_path = os.environ["PROXY_LIST_FILE"]
active_path = os.environ["ACTIVE_PROXY_FILE"]
idx = int(os.environ["ONE_BASED"]) - 1

with open(proxy_path, "r", encoding="utf-8") as f:
    items = json.load(f)
if idx < 0 or idx >= len(items):
    raise SystemExit("序号无效")
if len(items) <= 1:
    raise SystemExit("至少要保留一个上游出口，不能删除最后一个")

try:
    active = int(open(active_path, "r", encoding="utf-8").read().strip() or "0")
except Exception:
    active = 0
if active < 0 or active >= len(items):
    active = 0

deleted = items.pop(idx)
deleted_active = idx == active

if deleted_active:
    # Prefer the item that shifted into the deleted slot; if we deleted the
    # last item, fall back to the new last item.
    active = min(idx, len(items) - 1)
elif active > idx:
    # Keep the same logical active item after list indexes shift left.
    active -= 1

with open(proxy_path, "w", encoding="utf-8") as f:
    json.dump(items, f, ensure_ascii=False, indent=2)
    f.write("\n")
with open(active_path, "w", encoding="utf-8") as f:
    f.write(str(active) + "\n")

desc = f"{deleted.get('username','')}@{deleted.get('host')}:{deleted.get('port')}"
print("DELETED_ACTIVE=" + ("1" if deleted_active else "0"))
print("NEW_ACTIVE_ONE_BASED=" + str(active + 1))
print("DELETED_DESC=" + shlex.quote(desc))
PY
  )"
  eval "$result"
  chmod 600 "$PROXY_LIST_FILE" "$ACTIVE_PROXY_FILE"

  echo "已删除：$DELETED_DESC"
  if [[ "${DELETED_ACTIVE:-0}" == "1" ]]; then
    echo "删除的是当前出口，自动切换到 #$NEW_ACTIVE_ONE_BASED ..."
    proxy_apply_index "$NEW_ACTIVE_ONE_BASED"
    sing-box check -c "$CONFIG_FILE"
    if systemctl --quiet is-active sing-box; then
      systemctl restart sing-box
      echo "sing-box 已重启，当前出口已切换。"
    else
      echo "sing-box 当前未运行；配置已更新，下次启动生效。"
    fi
  else
    echo "删除的不是当前出口，无需重启 sing-box。"
  fi
}

cmd_proxy() {
  case "${1:-list}" in
    list|ls) proxy_list ;;
    add)
      shift || true
      proxy_add "${1:-}"
      ;;
    switch|use)
      if [[ -n "${2:-}" ]]; then
        switch_with_rollback "$2"
      else
        proxy_switch
      fi
      ;;
    delete|del|rm|remove)
      if [[ -n "${2:-}" ]]; then
        proxy_delete "$2"
      else
        proxy_delete
      fi
      ;;
    *)
      echo "Usage: sudo zck proxy list|add 用户名:密码@ip:端口|switch [序号]|delete [序号]"
      return 1
      ;;
  esac
}

cmd_status() {
  local unit
  echo "mode: $(cat "$MODE_FILE" 2>/dev/null || echo proxy)"
  for unit in egress-bypass sing-box; do
    if systemctl is-active --quiet "$unit"; then
      echo "$unit: active"
    else
      echo "$unit: inactive"
    fi
  done
  ip -brief link show "$TUN_NAME" 2>/dev/null || echo "$TUN_NAME: 不存在"
  sing-box version 2>/dev/null | head -1 || true
}

cmd_test() {
  echo "== 节点 (本机) =="
  printf 'DNS 解析 (ip.sb): '
  if timeout 15 getent ahostsv4 ip.sb | awk 'NR==1{print $1; ok=1} END{exit ok ? 0 : 1}'; then
    true
  else
    echo "失败"
  fi
  printf 'IPv4 出口 IP   : '
  local out
  if ! out="$(curl_egress_ip)"; then
    echo "失败 — 请执行 sudo zck diag"
  else
    echo "$out"
  fi

  if command -v incus >/dev/null 2>&1; then
    local guest gout
    guest=$(incus list -c n,s --format csv 2>/dev/null \
              | awk -F, '$2=="RUNNING"{print $1; exit}')
    if [[ -n "$guest" ]]; then
      echo
      echo "== 小鸡 ($guest) =="
      printf 'IPv4 出口 IP   : '
      gout=$(incus exec "$guest" -- bash -lc \
              'out="$(curl -4 --connect-timeout 12 --max-time 35 --retry 2 --retry-delay 2 -fsS https://ip.sb 2>/dev/null | tr -d "[:space:]" || true)"; echo "$out" | grep -Eq "^([0-9]{1,3}\.){3}[0-9]{1,3}$" && echo "$out"' 2>/dev/null || true)
      if [[ -z "$gout" ]]; then
        echo "失败"
      else
        echo "$gout"
      fi
    fi
  fi
}

cmd_diag() {
  echo "== 单元状态 =="
  systemctl --no-pager status egress-bypass sing-box 2>/dev/null || true
  echo
  echo "== 上游出口列表 =="
  proxy_list || true
  echo
  echo "== sing-box 最近日志 (last 60) =="
  journalctl -u sing-box -n 60 --no-pager || true
  echo
  echo "== TUN ($TUN_NAME) =="
  ip -brief addr show "$TUN_NAME" 2>/dev/null || echo "未建立"
  echo
  echo "== ip rules (v4) =="
  ip -4 rule show || true
  echo
  echo "== sing-box 路由表 (2022) =="
  ip -4 route show table 2022 2>/dev/null || true
  echo
  echo "== main 默认路由 =="
  ip -4 route show default || true
  echo
  echo "== egress-bypass nft 表 =="
  nft list table inet egress-bypass 2>/dev/null || echo "未加载"
  echo
  echo "== ip_forward =="
  sysctl net.ipv4.ip_forward 2>/dev/null || true
  sysctl net.ipv6.conf.all.forwarding 2>/dev/null || true
  echo
  echo "== 上游服务器 TCP 连通性 =="
  local srv prt typ
  read -r srv prt < <(python3 - <<'PY' 2>/dev/null
import json
try:
    with open("/etc/sing-box/config.json") as f:
        cfg = json.load(f)
    for o in cfg.get("outbounds", []):
        if o.get("tag") == "proxy":
            print(o.get("server",""), o.get("server_port","")); break
except Exception:
    pass
PY
)
  if [[ -n "${srv:-}" && -n "${prt:-}" ]]; then
    if command -v nc >/dev/null 2>&1; then
      if nc -z -w 5 "$srv" "$prt" 2>/dev/null; then
        echo "可达: $srv:$prt"
      else
        echo "不可达: $srv:$prt  <-- 上游服务器/防火墙问题"
      fi
    else
      echo "未安装 nc；上游地址：$srv:$prt"
    fi
  fi
}

cmd_logs()    { journalctl -u sing-box -f; }
cmd_check()   { sing-box check -c "$CONFIG_FILE"; }
cmd_restart() {
  sing-box check -c "$CONFIG_FILE"
  systemctl restart sing-box
  systemctl --no-pager status sing-box | head -10
}
cmd_repair() {
  /usr/local/sbin/egress-socks-check
  cmd_status
}
cmd_fallback() {
  local reason="${1:-manual fallback}"
  logger -t zck "fallback to local egress: ${reason}"
  systemctl disable --now sing-box                 >/dev/null 2>&1 || true
  systemctl disable --now egress-bypass            >/dev/null 2>&1 || true
  ip link delete "$TUN_NAME" >/dev/null 2>&1 || true
  nft delete table inet egress-bypass >/dev/null 2>&1 || true
  ip -4 rule del fwmark "$BYPASS_MARK" lookup main pref 8000 >/dev/null 2>&1 || true
  ip -6 rule del fwmark "$BYPASS_MARK" lookup main pref 8000 >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$MODE_FILE")"
  printf 'local\n' > "$MODE_FILE"
  chmod 600 "$MODE_FILE"
  /usr/local/sbin/egress-socks-notify fallback "$reason" >/dev/null 2>&1 || true
  echo "已回落本机原出口。自修复定时器会继续尝试恢复家宽 SOCKS/SS 出口。"
}
cmd_recover() {
  sing-box check -c "$CONFIG_FILE"
  systemctl enable --now egress-bypass >/dev/null 2>&1 || true
  systemctl enable --now sing-box >/dev/null 2>&1 || true
  sleep 2
  if curl_egress_ip >/dev/null; then
    printf 'proxy\n' > "$MODE_FILE"
    chmod 600 "$MODE_FILE"
    /usr/local/sbin/egress-socks-notify recover >/dev/null 2>&1 || true
    echo "家宽 SOCKS/SS 出口已恢复。"
    return 0
  fi
  cmd_fallback "recover test failed"
  return 1
}
cmd_off() {
  systemctl disable --now egress-socks-check.timer egress-socks-report.timer >/dev/null 2>&1 || true
  cmd_fallback "manual off" >/dev/null || true
  /usr/local/sbin/egress-socks-notify off >/dev/null 2>&1 || true
  echo "已关闭。流量恢复原始直连。"
}
cmd_on() {
  systemctl enable --now egress-bypass            >/dev/null 2>&1 || true
  systemctl enable --now sing-box                 >/dev/null 2>&1 || true
  systemctl enable --now egress-socks-check.timer >/dev/null 2>&1 || true
  systemctl enable --now egress-socks-report.timer >/dev/null 2>&1 || true
  systemctl start egress-socks-check.service      >/dev/null 2>&1 || true
  printf 'proxy\n' > "$MODE_FILE"
  chmod 600 "$MODE_FILE"
  /usr/local/sbin/egress-socks-notify recover >/dev/null 2>&1 || true
  cmd_status
}

case "${1:-status}" in
  status)  cmd_status  ;;
  test)    cmd_test    ;;
  diag)    cmd_diag    ;;
  proxy)   shift; cmd_proxy "$@" ;;
  logs)    cmd_logs    ;;
  check)   cmd_check   ;;
  restart) cmd_restart ;;
  repair)  cmd_repair  ;;
  fallback) cmd_fallback ;;
  recover) cmd_recover ;;
  off)     cmd_off     ;;
  on)      cmd_on      ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
EOF
  chmod +x "$HELPER_BIN"
}

install_reporter() {
  cat > "$NOTIFY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REPORT_ENV_FILE="/etc/egress-socks/report.env"
MODE_FILE="/etc/egress-socks/mode"
[[ -r "$REPORT_ENV_FILE" ]] && source "$REPORT_ENV_FILE" || true

TOKEN="${TG_BOT_TOKEN:-}"
CHAT_ID="${TG_CHAT_ID:-}"
NODE="${REPORT_NODE_NAME:-$(hostname -s 2>/dev/null || hostname)}"
EVENT="${1:-periodic}"
DETAIL="${2:-}"
LAST_FILE="/run/egress-socks-notify.last"

[[ -n "$TOKEN" && -n "$CHAT_ID" ]] || exit 0

mode="$(cat "$MODE_FILE" 2>/dev/null || echo proxy)"
case "$EVENT" in
  fallback)
    status="已回落本机出口"
    current="本机原出口"
    ;;
  recover|reconnect)
    status="已恢复家宽出口"
    current="家宽出口"
    ;;
  off|stop)
    status="已手动停止"
    current="本机原出口"
    ;;
  periodic)
    if [[ "$mode" == "local" ]]; then
      status="回落保护中"
      current="本机原出口"
    else
      status="出口正常"
      current="家宽出口"
    fi
    ;;
  *)
    status="$EVENT"
    current=$([[ "$mode" == "local" ]] && echo "本机原出口" || echo "家宽出口")
    ;;
esac

now="$(date '+%Y-%m-%d %H:%M:%S %Z')"
key="${EVENT}|${status}|${current}"
if [[ "$EVENT" != "periodic" ]]; then
  last_key=""
  last_ts=0
  if [[ -r "$LAST_FILE" ]]; then
    IFS='|' read -r last_ts last_key < "$LAST_FILE" || true
  fi
  ts="$(date +%s)"
  if [[ "$last_key" == "$key" && $((ts - last_ts)) -lt 1500 ]]; then
    exit 0
  fi
  printf '%s|%s\n' "$ts" "$key" > "$LAST_FILE" 2>/dev/null || true
fi

text="【家宽出口状态】
节点：${NODE}
状态：${status}
当前：${current}
时间：${now}"
if [[ -n "$DETAIL" && "$EVENT" != "periodic" ]]; then
  text="${text}
备注：已触发自修复"
fi

curl -fsS --max-time 10 \
  --data-urlencode "chat_id=${CHAT_ID}" \
  --data-urlencode "text=${text}" \
  "https://api.telegram.org/bot${TOKEN}/sendMessage" >/dev/null 2>&1 || true
EOF
  chmod 755 "$NOTIFY_BIN"

  cat > "$REPORT_UNIT" <<EOF
[Unit]
Description=Home egress Telegram status report
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${NOTIFY_BIN} periodic
EOF

  cat > "$REPORT_TIMER" <<'EOF'
[Unit]
Description=Report home egress status to Telegram

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
AccuracySec=30s
Persistent=true
Unit=egress-socks-report.service

[Install]
WantedBy=timers.target
EOF
}

install_self_heal() {
  cat > "$CHECK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/sing-box/config.json"
MODE_FILE="/etc/egress-socks/mode"
EGRESS_PROBE_URL="${EGRESS_PROBE_URL:-https://ip.sb}"
EGRESS_CONNECT_TIMEOUT="${EGRESS_CONNECT_TIMEOUT:-12}"
EGRESS_MAX_TIME="${EGRESS_MAX_TIME:-35}"
EGRESS_RETRIES="${EGRESS_RETRIES:-2}"
TUN_NAME="$(python3 - 2>/dev/null <<'PY' || echo egress-tun0
import json
try:
    with open("/etc/sing-box/config.json") as f:
        cfg = json.load(f)
    for ib in cfg.get("inbounds", []):
        if ib.get("type") == "tun":
            print(ib.get("interface_name", "egress-tun0"))
            break
    else:
        print("egress-tun0")
except Exception:
    print("egress-tun0")
PY
)"

repair=0
restart_singbox=0
mode="$(cat "$MODE_FILE" 2>/dev/null || echo proxy)"

probe_proxy_egress() {
  local out
  out="$(curl -4 --connect-timeout "$EGRESS_CONNECT_TIMEOUT" --max-time "$EGRESS_MAX_TIME" --retry "$EGRESS_RETRIES" --retry-delay 2 -fsS "$EGRESS_PROBE_URL" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$out" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

if [[ "$mode" == "local" ]]; then
  if /usr/local/bin/zck recover >/dev/null 2>&1; then
    logger -t egress-socks-check "proxy egress recovered"
  else
    logger -t egress-socks-check "proxy egress still unavailable; keeping local egress"
  fi
  exit 0
fi

need_repair() {
  repair=1
  logger -t egress-socks-check "$*"
}

sing-box check -c "$CONFIG_FILE" >/dev/null || {
  logger -t egress-socks-check "sing-box config check failed"
  exit 1
}

systemctl is-active --quiet egress-bypass.service || need_repair "egress-bypass is not running"
nft list table inet egress-bypass >/dev/null 2>&1 || need_repair "egress-bypass nft table missing"
ip -4 rule show | grep -q 'fwmark 0x42 lookup main' || need_repair "egress bypass fwmark rule missing"

if ! systemctl is-active --quiet sing-box.service; then
  restart_singbox=1
  need_repair "sing-box is not running"
fi
ip link show "$TUN_NAME" >/dev/null 2>&1 || {
  restart_singbox=1
  need_repair "TUN interface ${TUN_NAME} is missing"
}

if (( repair )); then
  systemctl restart egress-bypass.service || true
fi
if (( restart_singbox )); then
  systemctl restart sing-box.service || true
fi

if ! probe_proxy_egress; then
  /usr/local/bin/zck fallback "ip.sb proxy IPv4 egress probe failed" >/dev/null 2>&1 || true
  exit 0
fi
EOF
  chmod 755 "$CHECK_BIN"

  cat > "$CHECK_UNIT" <<EOF
[Unit]
Description=Egress SOCKS self-healing check
After=network-online.target egress-bypass.service sing-box.service
Wants=network-online.target egress-bypass.service sing-box.service

[Service]
Type=oneshot
ExecStart=${CHECK_BIN}
EOF

  cat > "$CHECK_TIMER" <<'EOF'
[Unit]
Description=Run Egress SOCKS self-healing check

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=20s
Persistent=true
Unit=egress-socks-check.service

[Install]
WantedBy=timers.target
EOF

  mkdir -p /etc/systemd/system/sing-box.service.d
  cat > /etc/systemd/system/sing-box.service.d/20-egress-restart.conf <<'EOF'
[Service]
Restart=on-failure
RestartSec=5s
EOF
  systemctl daemon-reload
  systemctl enable --now egress-socks-check.timer >/dev/null 2>&1 || true
  systemctl enable --now egress-socks-report.timer >/dev/null 2>&1 || true
}

# =============================================================================
# 6. Enable services + verify
# =============================================================================
enable_and_verify() {
  log "[6/6] 启动服务并校验"

  sysctl -w net.ipv4.ip_forward=1               >/dev/null 2>&1 || true
  if [[ "$TUN_IPV6" == "1" ]]; then
    sysctl -w net.ipv6.conf.all.forwarding=1    >/dev/null 2>&1 || true
  else
    sysctl -w net.ipv6.conf.all.forwarding=0    >/dev/null 2>&1 || true
  fi
  cat > /etc/sysctl.d/99-egress-socks.conf <<SYSCTL
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=${TUN_IPV6}
SYSCTL

  systemctl enable --now egress-bypass.service

  # CRITICAL: do not let sing-box start until the kernel-side bypass is
  # fully committed. Otherwise the brief window where TUN owns routing but
  # nft/ip-rule aren't loaded yet will drop the operator's live SSH
  # session (sshd reply to a remote client gets reproxied via SOCKS,
  # peer RSTs).
  local tries=0
  while (( tries < 50 )); do
    if nft list table inet egress-bypass >/dev/null 2>&1 \
       && ip -4 rule show 2>/dev/null | grep -q "fwmark $BYPASS_MARK_HEX"; then
      break
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  if ! nft list table inet egress-bypass >/dev/null 2>&1 \
     || ! ip -4 rule show 2>/dev/null | grep -q "fwmark $BYPASS_MARK_HEX"; then
    echo
    echo "FATAL: egress-bypass 未能落地 nft 表 / ip rule，拒绝启动 sing-box。"
    echo "       这是为了避免 SSH 在生效窗口内被代理打断。"
    echo "       检查：systemctl status egress-bypass.service"
    echo "             journalctl -u egress-bypass.service -n 40 --no-pager"
    echo "             $BYPASS_APPLY        # 手动跑看错误"
    exit 1
  fi
  echo "  bypass 已就位 (耗时 $((tries * 100))ms)，安全启动 sing-box..."

  sing-box check -c "$CONFIG_FILE"
  schedule_rollback_guard
  systemctl enable --now sing-box

  sleep 2

  local ok=1
  local fallback_mode=0
  echo
  if systemctl --quiet is-active egress-bypass; then
    echo "  [OK]   egress-bypass 服务已启用"
  else
    echo "  [FAIL] egress-bypass 服务未启用"; ok=0
  fi

  if nft list table inet egress-bypass >/dev/null 2>&1; then
    echo "  [OK]   nft 表 inet egress-bypass 已加载"
  else
    echo "  [FAIL] nft 表 inet egress-bypass 缺失"; ok=0
  fi

  if ip -4 rule show | grep -q "fwmark $BYPASS_MARK_HEX"; then
    echo "  [OK]   IPv4 fwmark 策略路由已添加"
  else
    echo "  [FAIL] IPv4 fwmark 策略路由缺失"; ok=0
  fi

  if systemctl --quiet is-active sing-box; then
    echo "  [OK]   sing-box 运行中"
  else
    echo "  [FAIL] sing-box 未运行 — 最近日志："
    journalctl -u sing-box -n 30 --no-pager || true
    ok=0
  fi

  if ip link show "$TUN_NAME" >/dev/null 2>&1; then
    echo "  [OK]   TUN $TUN_NAME 已建立"
  else
    echo "  [FAIL] TUN $TUN_NAME 未建立"; ok=0
  fi

  local egress_ip
  egress_ip="$(curl_egress_ip || true)"
  if [[ -n "$egress_ip" ]]; then
    echo "  [OK]   真实出口测试通过: $egress_ip"
    printf 'proxy\n' > "$MODE_FILE"
    chmod 600 "$MODE_FILE"
  else
    echo "  [WARN] 真实出口测试失败；立即回落本机原出口，自修复会每 5 分钟尝试恢复家宽 SOCKS/SS。"
    /usr/local/bin/zck fallback "initial proxy IPv4 egress test failed" >/dev/null 2>&1 || true
    printf 'local\n' > "$MODE_FILE"
    chmod 600 "$MODE_FILE"
    fallback_mode=1
  fi

  echo
  if (( ok )); then
    touch "$ROLLBACK_SENTINEL"
    if (( fallback_mode )); then
      echo "已安全回落本机原出口。自修复保留开启，会每 5 分钟尝试恢复家宽 SOCKS/SS 出口。"
    else
      echo "全部就绪。验证出口 IP：sudo zck test"
    fi
    /usr/local/sbin/egress-socks-notify periodic >/dev/null 2>&1 || true
    echo "管理上游出口：sudo zck proxy list | add socks5://用户名:密码@ip:端口 或 ss://加密:密码@ip:端口 | switch"
    echo "若 IPv4 出口 IP 等于节点真实 IP，请运行 sudo zck diag 查看上游连通性。"
    echo "TG 上报：每 30 分钟上报一次，回落/恢复立即上报；消息不包含具体 IP。"
  else
    echo "存在失败项，请先按上面输出排查；详情请 sudo zck diag。"
  fi
}

main() {
  validate_inputs
  cleanup_all
  configure_report_settings
  install_packages
  write_singbox_config
  write_bypass_unit
  install_helper
  install_reporter
  install_self_heal
  enable_and_verify
}

main "$@"
