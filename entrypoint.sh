#!/bin/bash
set -e

# 1) Ensure /dev/net/tun exists (not strictly required for TPROXY, but harmless)
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

# 4) Apply TPROXY rules (force legacy iptables to avoid nf_tables issues)
IPT="iptables"
IP6T="ip6tables"

if command -v iptables-legacy >/dev/null 2>&1; then
  IPT="iptables-legacy"
fi
if command -v ip6tables-legacy >/dev/null 2>&1; then
  IP6T="ip6tables-legacy"
fi

TPROXY_PORT="12345"
FW_MARK="1"
TABLE_ID="100"

# qBittorrent user (linuxserver images normally run as user 'abc')
QB_UID=""
if id -u abc >/dev/null 2>&1; then
  QB_UID="$(id -u abc)"
  echo "[entrypoint] Detected qB user: abc (uid=$QB_UID)"
else
  echo "[entrypoint] WARNING: user abc not found. Will tproxy ALL local traffic (more aggressive)."
fi

# 4.1) Policy routing for TPROXY-marked packets
ip rule del fwmark ${FW_MARK} lookup ${TABLE_ID} 2>/dev/null || true
ip route flush table ${TABLE_ID} 2>/dev/null || true
ip rule add fwmark ${FW_MARK} lookup ${TABLE_ID}
ip route add local 0.0.0.0/0 dev lo table ${TABLE_ID}

# 4.2) Chains
$IPT -t mangle -N XRAY_TPROXY 2>/dev/null || true
$IPT -t mangle -F XRAY_TPROXY

$IPT -t mangle -N XRAY_DIVERT 2>/dev/null || true
$IPT -t mangle -F XRAY_DIVERT
$IPT -t mangle -A XRAY_DIVERT -j MARK --set-mark ${FW_MARK}
$IPT -t mangle -A XRAY_DIVERT -j ACCEPT

# (Optional optimization) Divert packets for existing local sockets
# If your kernel/iptables doesn't support -m socket, these lines may fail.
# In that case, comment them out.
$IPT -t mangle -C PREROUTING -p tcp -m socket -j XRAY_DIVERT 2>/dev/null || \
  $IPT -t mangle -A PREROUTING -p tcp -m socket -j XRAY_DIVERT

# 4.3) Bypass local/private and Docker DNS to avoid loops & keep LAN direct
$IPT -t mangle -A XRAY_TPROXY -d 127.0.0.0/8 -j RETURN
$IPT -t mangle -A XRAY_TPROXY -d 10.0.0.0/8 -j RETURN
$IPT -t mangle -A XRAY_TPROXY -d 172.16.0.0/12 -j RETURN
$IPT -t mangle -A XRAY_TPROXY -d 192.168.0.0/16 -j RETURN
$IPT -t mangle -A XRAY_TPROXY -d 127.0.0.11/32 -j RETURN

# 4.4) TPROXY redirect (TCP+UDP) to Xray's tproxy-in port
$IPT -t mangle -A XRAY_TPROXY -p tcp -j TPROXY --on-port ${TPROXY_PORT} --tproxy-mark 0x${FW_MARK}/0x${FW_MARK}
$IPT -t mangle -A XRAY_TPROXY -p udp -j TPROXY --on-port ${TPROXY_PORT} --tproxy-mark 0x${FW_MARK}/0x${FW_MARK}

# 4.5) Attach to OUTPUT (only qB user traffic if possible)
# remove old attachments then re-add
$IPT -t mangle -D OUTPUT -j XRAY_TPROXY 2>/dev/null || true
if [ -n "$QB_UID" ]; then
  $IPT -t mangle -A OUTPUT -m owner --uid-owner "$QB_UID" -j XRAY_TPROXY
else
  $IPT -t mangle -A OUTPUT -j XRAY_TPROXY
fi

echo "[entrypoint] TPROXY rules applied via $IPT"

# 5) Start qBittorrent via linuxserver init
exec /init
