# qBittorrent with Xray Tunnel

[![Weekly Build](https://github.com/DamnCrab/qbittorrent-xray/actions/workflows/docker-build.yml/badge.svg)](https://github.com/DamnCrab/qbittorrent-xray/actions/workflows/docker-build.yml)

一个集成了 [Xray-core](https://github.com/XTLS/Xray-core) 的 qBittorrent Docker 镜像，基于 [LinuxServer.io](https://docs.linuxserver.io/images/docker-qbittorrent) 构建，专为需要代理流量的场景设计。

## ✨ 特性

- **🏗 多架构支持**：同时支持 `linux/amd64` 和 `linux/arm64` (包括 Apple Silicon)。
- **🟢 开箱即用**：基于 LinuxServer 稳定镜像，集成 Xray 核心。
- **🔄 自动更新**：包含 [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) 增强版规则 (GeoIP, GeoSite)。
- **🛡 灵活配置**：支持挂载自定义 Xray 配置文件。
- **🔌 TUN 支持**：默认开启 TUN 设备支持。

## 🚀 快速部署

使用 Docker Compose 部署是最简单的方式。

1. 创建 `docker-compose.yml`：

```yaml
services:
  qb-xray:
    image: ghcr.io/damncrab/qbittorrent-xray:latest
    container_name: qb-xray
    restart: unless-stopped
    cap_add:
      - NET_ADMIN # 必须开启，以支持 TUN 模式
    devices:
      - /dev/net/tun:/dev/net/tun # 映射 TUN 设备
    environment:
      - PUID=1000
      - PGID=100
      - TZ=Asia/Shanghai
      - WEBUI_PORT=8080
    volumes:
      - ./data/config:/config # qBittorrent 配置目录
      - ./data/xray:/etc/xray # Xray 配置目录
      - ./data/downloads:/downloads # 下载目录
    ports:
      - "8080:8080" # WebUI 端口
    # 如果你需要通过 macvlan 或 host 网络模式运行，请按需调整网络配置
```

2. 准备 Xray 配置文件：

在 `./data/xray/` 目录下创建 `config.json`。

> ⚠️ **注意**：如果不提供 `config.json`，容器将尝试使用内置模板，但强烈建议挂载你自己的配置以确保代理可用。

3. 启动容器：

```bash
docker-compose up -d
```

## ⚙️ 配置说明

### qBittorrent 代理设置
进入 WebUI (默认 `http://IP:8080`)，在 `设置` -> `连接` -> `代理服务器` 中配置：

- **类型**: `SOCKS5`
- **主机**: `127.0.0.1`
- **端口**: `10808` (假设你的 Xray 入站端口配置为 10808)
- **勾选**: `对 BitTorrent 使用代理` (可选，根据需求)

如果你的 Xray 配置了 **透明代理** (TProxy/TUN)，则可能不需要在 qBittorrent 内部设置代理，只需确保容器内的流量被路由表规则捕获即可。

### Xray 配置
Xray 默认读取 `/etc/xray/config.json`。GeoIP 和 GeoSite 文件位于 `/usr/bin/geoip.dat` 和 `/usr/bin/geosite.dat`，可在配置文件中直接引用 `geoip.dat` 和 `geosite.dat`。

## 🛠 手动构建

如果你想手动构建此镜像：

```bash
# 构建当前架构
docker build -t qb-xray-local .

# 构建多架构 (需 Docker Buildx)
docker buildx build --platform linux/amd64,linux/arm64 -t your-repo/qb-xray:latest .
```