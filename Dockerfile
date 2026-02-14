FROM lscr.io/linuxserver/qbittorrent:latest

# 安装必要工具
RUN apk add --no-cache curl unzip ca-certificates gettext

# 安装最新版 Xray
RUN set -ex && \
    curl -L -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" && \
    unzip /tmp/xray.zip -d /tmp && \
    mv /tmp/xray /usr/bin/xray && \
    chmod +x /usr/bin/xray && \
    rm /tmp/xray.zip

# 安装 Loyalsoldier 增强版资源文件
RUN curl -L -o /usr/bin/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat && \
    curl -L -o /usr/bin/geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat

# 创建一个专门存放镜像内置模板的目录（不要挂载这个目录）
RUN mkdir -p /usr/share/xray

# 将本地配置复制到模板目录
COPY xray_config.json /usr/share/xray/config.template

# 复制脚本
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]