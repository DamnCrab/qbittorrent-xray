#!/bin/bash

# 1. 确保 TUN 设备存在
if [ ! -c /dev/net/tun ]; then
    mkdir -p /dev/net/tun
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# 2. 定义路径
XRAY_CONFIG="/etc/xray/config.json"
XRAY_TEMPLATE="/usr/share/xray/config.template" # 模板现在在这里

# 3. 配置文件逻辑
if [ -f "$XRAY_CONFIG" ]; then
    echo "Using existing Xray config found at $XRAY_CONFIG (Mounted)"
else
    echo "No config found in /etc/xray, checking template..."
    if [ -f "$XRAY_TEMPLATE" ]; then
        echo "Generating config from internal template..."
        # 确保 /etc/xray 目录存在（如果挂载没成功或者没挂载）
        mkdir -p /etc/xray
        envsubst < "$XRAY_TEMPLATE" > "$XRAY_CONFIG"
    else
        echo "Fatal Error: Template not found at $XRAY_TEMPLATE"
        exit 1
    fi
fi

# 4. 启动 Xray
/usr/bin/xray run -c "$XRAY_CONFIG" &

# 5. 启动 qBittorrent
exec /init