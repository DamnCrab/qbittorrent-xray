#!/bin/bash
set -e

# 1) Ensure /dev/net/tun exists
if [ ! -c /dev/net/tun ]; then
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200 || true
  chmod 600 /dev/net/tun || true
fi

XRAY_CONFIG="/etc/xray/config.json"
XRAY_TEMPLATE="/usr/share/xray/config.template"

# 2) Config generation logic (use mounted config if present; otherwise template)
if [ -f "$XRAY_CONFIG" ]; then
  echo "[entrypoint] Using existing Xray config at $XRAY_CONFIG"
else
  echo "[entrypoint] No config found at /etc/xray, generating from template..."
  if [ -f "$XRAY_TEMPLATE" ]; then
    mkdir -p /etc/xray
    envsubst < "$XRAY_TEMPLATE" > "$XRAY_CONFIG"
  else
    echo "[entrypoint] Fatal Error: Template not found at $XRAY_TEMPLATE"
    exit 1
  fi
fi

# 3) Start Xray in background
/usr/bin/xray run -c "$XRAY_CONFIG" &
XRAY_PID=$!
echo "[entrypoint] Xray started, pid=$XRAY_PID"

# 4) Best-effort cleanup of legacy TPROXY rules from older image versions
ip rule del fwmark 1 lookup 100 2>/dev/null || true
ip route flush table 100 2>/dev/null || true

if command -v iptables >/dev/null 2>&1; then
  IPT="iptables"
  if command -v iptables-legacy >/dev/null 2>&1; then
    IPT="iptables-legacy"
  fi

  while $IPT -t mangle -D OUTPUT -j XRAY_TPROXY 2>/dev/null; do :; done
  while $IPT -t mangle -D PREROUTING -p tcp -m socket -j XRAY_DIVERT 2>/dev/null; do :; done
  $IPT -t mangle -F XRAY_TPROXY 2>/dev/null || true
  $IPT -t mangle -X XRAY_TPROXY 2>/dev/null || true
  $IPT -t mangle -F XRAY_DIVERT 2>/dev/null || true
  $IPT -t mangle -X XRAY_DIVERT 2>/dev/null || true
fi

# 5) Configure TUN routing for qBittorrent traffic (TCP + UDP)
TUN_IFACE="${XRAY_TUN_IFACE:-}"
if [ -z "$TUN_IFACE" ]; then
  TUN_IFACE="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$XRAY_CONFIG" | head -n1)"
fi
TUN_IFACE="${TUN_IFACE:-xray0}"

TUN_ADDR="${XRAY_TUN_ADDR:-10.251.0.1/30}"
TUN_TABLE="${XRAY_TUN_TABLE:-1001}"
TUN_RULE_PREF="${XRAY_TUN_RULE_PREF:-100}"
BYPASS_PREF_BASE="${XRAY_BYPASS_PREF_BASE:-80}"
BYPASS_CIDRS="${XRAY_BYPASS_CIDRS:-127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16}"

# Wait until Xray creates the tun interface
for _ in $(seq 1 40); do
  if ip link show "$TUN_IFACE" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

if ! ip link show "$TUN_IFACE" >/dev/null 2>&1; then
  echo "[entrypoint] Fatal Error: TUN interface '$TUN_IFACE' was not created by Xray."
  kill "$XRAY_PID" 2>/dev/null || true
  exit 1
fi

ip link set dev "$TUN_IFACE" up
ip addr replace "$TUN_ADDR" dev "$TUN_IFACE"

# qBittorrent user (linuxserver images normally run as user 'abc')
QB_UID="${XRAY_QB_UID:-}"
QB_UID_SRC=""
if [ -n "$QB_UID" ]; then
  QB_UID_SRC="XRAY_QB_UID"
elif id -u abc >/dev/null 2>&1; then
  QB_UID="$(id -u abc)"
  QB_UID_SRC="abc"
elif [ -n "${PUID:-}" ]; then
  QB_UID="$PUID"
  QB_UID_SRC="PUID"
fi

# Route only qBittorrent traffic via tun to avoid looping Xray's own uplink traffic
ip route flush table "$TUN_TABLE" 2>/dev/null || true
ip route add default dev "$TUN_IFACE" table "$TUN_TABLE"
ip rule del pref "$TUN_RULE_PREF" 2>/dev/null || true

OLD_IFS="$IFS"
IFS=',' read -r -a BYPASS_LIST <<< "$BYPASS_CIDRS"
IFS="$OLD_IFS"

add_uid_bypass_rules() {
  local uidrange="$1"
  local pref="$BYPASS_PREF_BASE"
  local cidr

  for cidr in "${BYPASS_LIST[@]}"; do
    [ -z "$cidr" ] && continue
    ip rule del pref "$pref" uidrange "$uidrange" to "$cidr" lookup main 2>/dev/null || true
    ip rule add pref "$pref" uidrange "$uidrange" to "$cidr" lookup main
    pref=$((pref + 1))
  done
}

if [ -n "$QB_UID" ]; then
  add_uid_bypass_rules "${QB_UID}-${QB_UID}"
  ip rule add pref "$TUN_RULE_PREF" uidrange "${QB_UID}-${QB_UID}" lookup "$TUN_TABLE"
  echo "[entrypoint] TUN routing enabled on $TUN_IFACE via table $TUN_TABLE for qB uid=$QB_UID (source=$QB_UID_SRC, pref=$TUN_RULE_PREF, bypass=$BYPASS_CIDRS)"
else
  # Best-effort fallback when user id cannot be detected: route all non-root traffic.
  add_uid_bypass_rules "1-4294967294"
  ip rule add pref "$TUN_RULE_PREF" uidrange "1-4294967294" lookup "$TUN_TABLE"
  echo "[entrypoint] WARNING: qB uid not found, routing all non-root traffic via $TUN_IFACE (pref=$TUN_RULE_PREF, bypass=$BYPASS_CIDRS)"
fi

# 6) Start qBittorrent via linuxserver init
exec /init
