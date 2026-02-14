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
QB_CONF="/config/qBittorrent/qBittorrent.conf"
QB_DEFAULT_PORT="${XRAY_QB_FIRST_RUN_PORT:-51413}"

is_valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

detect_qb_port_from_conf() {
  local file="$1"
  local port
  [ -f "$file" ] || return 0

  port="$(sed -n 's/^Session\\Port=\([0-9][0-9]*\)\r\?$/\1/p' "$file" | head -n1)"
  if [ -z "$port" ]; then
    port="$(sed -n 's/^Connection\\PortRangeMin=\([0-9][0-9]*\)\r\?$/\1/p' "$file" | head -n1)"
  fi
  printf '%s\n' "$port"
}

set_ini_value() {
  local file="$1"
  local section="$2"
  local key="$3"
  local value="$4"
  local tmp_file

  tmp_file="$(mktemp)"
  awk -v section="$section" -v key="$key" -v value="$value" '
    BEGIN {
      in_section = 0
      section_found = 0
      key_written = 0
    }
    /^\[/ {
      if (in_section && !key_written) {
        print key "=" value
        key_written = 1
      }
      in_section = ($0 == "[" section "]")
      if (in_section) {
        section_found = 1
      }
      print
      next
    }
    {
      if (in_section && index($0, key "=") == 1) {
        if (!key_written) {
          print key "=" value
          key_written = 1
        }
        next
      }
      print
    }
    END {
      if (!section_found) {
        print ""
        print "[" section "]"
        print key "=" value
      } else if (in_section && !key_written) {
        print key "=" value
      }
    }
  ' "$file" > "$tmp_file"

  cat "$tmp_file" > "$file"
  rm -f "$tmp_file"
}

sync_qb_port_settings() {
  local file="$1"
  local port="$2"

  if [ ! -f "$file" ]; then
    echo "[entrypoint] qB config not found yet. Will rely on TORRENTING_PORT=$port during initialization."
    return
  fi

  set_ini_value "$file" "BitTorrent" "Session\\Port" "$port"
  set_ini_value "$file" "Preferences" "Connection\\PortRangeMin" "$port"
  echo "[entrypoint] qB config synced: Session\\Port=$port, Connection\\PortRangeMin=$port"
}

sync_xray_redirect_port() {
  local file="$1"
  local port="$2"

  if grep -Eq '"redirect"[[:space:]]*:[[:space:]]*"127\.0\.0\.1:[^"]+"' "$file"; then
    sed -E -i 's/("redirect"[[:space:]]*:[[:space:]]*"127\.0\.0\.1:)[^"]+"/\1'"$port"'"/g' "$file"
    echo "[entrypoint] Xray redirect synced to 127.0.0.1:$port"
  else
    echo "[entrypoint] Xray redirect not found in $file, skipped."
  fi
}

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

# 3) Resolve torrent port, then sync qB/Xray to the same value
RESOLVED_TORRENT_PORT="${TORRENTING_PORT:-}"
if [ -z "$RESOLVED_TORRENT_PORT" ]; then
  RESOLVED_TORRENT_PORT="$(detect_qb_port_from_conf "$QB_CONF")"
fi
if ! is_valid_port "$RESOLVED_TORRENT_PORT"; then
  RESOLVED_TORRENT_PORT="$QB_DEFAULT_PORT"
fi
if ! is_valid_port "$RESOLVED_TORRENT_PORT"; then
  RESOLVED_TORRENT_PORT="51413"
fi

export TORRENTING_PORT="$RESOLVED_TORRENT_PORT"
echo "[entrypoint] Effective TORRENTING_PORT=$TORRENTING_PORT"

sync_qb_port_settings "$QB_CONF" "$TORRENTING_PORT"
sync_xray_redirect_port "$XRAY_CONFIG" "$TORRENTING_PORT"

# 4) Start Xray in background
/usr/bin/xray run -c "$XRAY_CONFIG" &
XRAY_PID=$!
echo "[entrypoint] Xray started, pid=$XRAY_PID"

# 5) Best-effort cleanup of legacy TPROXY rules from older image versions
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

# 6) Configure TUN routing for qBittorrent traffic (TCP + UDP)
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

# 7) Start qBittorrent via linuxserver init
exec /init
