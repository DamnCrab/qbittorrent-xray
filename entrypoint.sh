#!/bin/bash
set -e

# 1) 确保 TUN 设备存在（虽然我们走 TPROXY，但保留不影响）
if [ ! -c /dev/net/tun ]; then
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200 || true
  chmod 600 /dev/net/tun || true
fi

XRAY_CONFIG="/etc/xray/config.json"
XRAY_TEMPLATE="/usr/share/xray/config.template"

# 2) 生成/使用 Xray 配置
if [ -f "$XRAY_CONFIG" ]; then
  echo "[entrypoint] Using existing Xray config at $XRAY_CONFIG"
else
  echo "[entrypoint] No config in /etc/xray, generating from template..."
  if [ -f "$XRAY_TEMPLATE" ]; then
    mkdir -p /etc/xray
    envsubst < "$XRAY_TEMPLATE" > "$XRAY_CONFIG"
  else
    echo "[entrypoint] Fatal: template not found at $XRAY_TEMPLATE"
    exit 1
  fi
fi

# 3) 启动 Xray（后台）
/usr/bin/xray run -c "$XRAY_CONFIG" &
XRAY_PID=$!
echo "[entrypoint] Xray started, pid=$XRAY_PID"

# 4) 安装透明代理（TPROXY）规则：只劫持 qB 用户流量，避免把 Xray 自己劫持死循环
#    linuxserver 的 qB 通常是用户 abc；若不存在则退化为不加 owner 匹配（会更激进）
TPROXY_PORT="12345"
FW_MARK="1"
TABLE_ID="100"

QB_UID=""
if id -u abc >/dev/null 2>&1; then
  QB_UID="$(id -u abc)"
  echo "[entrypoint] Detected qB user: abc (uid=$QB_UID)"
else
  echo "[entrypoint] WARNING: user abc not found. Will tproxy ALL local traffic (more aggressive)."
fi

# 4.1) policy routing
# 清理旧的 rule/route（容器重启时避免重复报错）
ip rule del fwmark ${FW_MARK} lookup ${TABLE_ID} 2>/dev/null || true
ip route flush table ${TABLE_ID} 2>/dev/null || true

ip rule add fwmark ${FW_MARK} lookup ${TABLE_ID}
ip route add local 0.0.0.0/0 dev lo table ${TABLE_ID}

# 4.2) mangle 规则：创建自定义链，便于管理
iptables -t mangle -N XRAY_TPROXY 2>/dev/null || true
iptables -t mangle -F XRAY_TPROXY

# 放行：本地/内网/保留地址，避免死循环 & 保证局域网直连
iptables -t mangle -A XRAY_TPROXY -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A XRAY_TPROXY -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A XRAY_TPROXY -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A XRAY_TPROXY -d 192.168.0.0/16 -j RETURN

# 放行：Docker 内置 DNS（127.0.0.11），否则解析可能异常
iptables -t mangle -A XRAY_TPROXY -d 127.0.0.11/32 -j RETURN

# 关键：TPROXY 到本地端口，并打 mark
iptables -t mangle -A XRAY_TPROXY -p tcp -j TPROXY --on-port ${TPROXY_PORT} --tproxy-mark 0x${FW_MARK}/0x${FW_MARK}
iptables -t mangle -A XRAY_TPROXY -p udp -j TPROXY --on-port ${TPROXY_PORT} --tproxy-mark 0x${FW_MARK}/0x${FW_MARK}

# 4.3) 挂到 OUTPUT：仅劫持 qB 用户（abc）发起的流量
# 如果没找到 abc 用户，则劫持全部 OUTPUT（不推荐长期这样用）
iptables -t mangle -D OUTPUT -j XRAY_TPROXY 2>/dev/null || true
if [ -n "]()
