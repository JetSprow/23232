#!/usr/bin/env bash
# Diagnose why raw.githubusercontent.com / Check.Place hangs on this node.
# Usage: sudo bash diagnose-github-raw.sh 2>&1 | tee /tmp/github-raw-diagnose.log
set -uo pipefail

RAW_URL="https://raw.githubusercontent.com/xykt/ScriptMenu/main/menu.sh"
CHECK_URL="https://Check.Place"
RAW_HOST="raw.githubusercontent.com"
GITHUB_HOST="github.com"
TIMEOUT_SHORT=8
TIMEOUT_LONG=18

section() {
  printf '\n========== %s ==========\n' "$*"
}

run() {
  local title="$1"
  shift
  section "$title"
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  timeout "$TIMEOUT_LONG" "$@"
  local code=$?
  printf '\n[exit=%s]\n' "$code"
}

run_short() {
  local title="$1"
  shift
  section "$title"
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  timeout "$TIMEOUT_SHORT" "$@"
  local code=$?
  printf '\n[exit=%s]\n' "$code"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

section "basic"
date -Is 2>/dev/null || date
hostname 2>/dev/null || true
uname -a 2>/dev/null || true
printf 'uid=%s shell=%s\n' "$(id -u 2>/dev/null || echo unknown)" "${SHELL:-unknown}"

section "system dns"
ls -l /etc/resolv.conf 2>/dev/null || true
cat /etc/resolv.conf 2>/dev/null || true
if have resolvectl; then
  resolvectl status 2>/dev/null | sed -n '1,120p' || true
fi

section "routes and rules"
ip -4 route show table main 2>/dev/null || true
ip -4 rule show 2>/dev/null || true
ip -4 addr show 2>/dev/null || true
ip link show 2>/dev/null | sed -n '1,160p' || true

if have wg; then
  section "wireguard"
  wg show 2>/dev/null || true
fi

section "firewall hints"
iptables -t mangle -S 2>/dev/null | grep -E 'wg0|51820|dport 53|TCPMSS|CONNMARK|MARK' || true
iptables -t nat -S 2>/dev/null | grep -E 'wg0|dport 53|MASQUERADE|DNAT' || true
iptables -S 2>/dev/null | grep -E 'wg0|dport 53|853|6881|6889' || true

section "public ip quick checks"
run_short "curl ip.sb" curl -4 -sS --connect-timeout 4 --max-time 8 https://ip.sb
run_short "curl ifconfig.me" curl -4 -sS --connect-timeout 4 --max-time 8 https://ifconfig.me

section "dns resolution"
for host in "$RAW_HOST" "$GITHUB_HOST" "Check.Place" "ip.sb"; do
  echo "-- $host"
  getent ahostsv4 "$host" 2>&1 | sed -n '1,12p'
done

RAW_IPS="$(getent ahostsv4 "$RAW_HOST" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
CHECK_IPS="$(getent ahostsv4 "Check.Place" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"

section "route to resolved ips"
for ip in $RAW_IPS $CHECK_IPS; do
  echo "-- $ip"
  ip -4 route get "$ip" 2>&1 || true
done

section "curl check.place"
run "Check.Place verbose with redirect" curl -4 -Lv --connect-timeout 5 --max-time 18 "$CHECK_URL" -o /tmp/check.place.out

section "curl raw default"
run "raw default" curl -4 -Lv --connect-timeout 5 --max-time 18 "$RAW_URL" -o /tmp/raw.default.out

section "curl raw http1.1"
run "raw forced HTTP/1.1" curl -4 -Lv --http1.1 --connect-timeout 5 --max-time 18 "$RAW_URL" -o /tmp/raw.http1.out

section "curl raw tls1.2"
run "raw forced TLS1.2" curl -4 -Lv --tls-max 1.2 --connect-timeout 5 --max-time 18 "$RAW_URL" -o /tmp/raw.tls12.out

section "curl github main"
run "github.com verbose" curl -4 -Lv --connect-timeout 5 --max-time 18 "https://github.com" -o /tmp/github.main.out

section "openssl raw sni per ip"
if have openssl; then
  for ip in $RAW_IPS; do
    run_short "openssl raw SNI $ip" openssl s_client -connect "${ip}:443" -servername "$RAW_HOST" -brief
  done
else
  echo "openssl not found"
fi

section "curl raw per ip with --resolve"
for ip in $RAW_IPS; do
  run_short "curl raw via $ip" curl -4 -Lv --resolve "${RAW_HOST}:443:${ip}" --connect-timeout 4 --max-time 8 "$RAW_URL" -o "/tmp/raw.${ip}.out"
done

section "mtu probes"
if have ping && [ -n "${RAW_IPS:-}" ]; then
  first_raw_ip="$(printf '%s\n' $RAW_IPS | head -n1)"
  for size in 1472 1400 1360 1280 1200; do
    echo "-- ping DF size=$size to $first_raw_ip"
    timeout 5 ping -4 -c 2 -M do -s "$size" "$first_raw_ip" 2>&1 || true
  done
else
  echo "ping not found or raw ip missing"
fi

section "trace"
if have tracepath; then
  tracepath -4 -m 12 "$RAW_HOST" 2>&1 || true
elif have traceroute; then
  traceroute -4 -m 12 "$RAW_HOST" 2>&1 || true
else
  echo "tracepath/traceroute not found"
fi

section "summary files"
ls -lh /tmp/check.place.out /tmp/raw.default.out /tmp/raw.http1.out /tmp/raw.tls12.out /tmp/github.main.out 2>/dev/null || true

section "done"
echo "Send the full output above."
