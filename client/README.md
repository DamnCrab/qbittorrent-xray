# qbittorrent-xray

将 qBittorrent 和 Xray 打包在同一个容器里，核心目标是：
通过 Xray 透明接管 qB 的 TCP/UDP 流量，并配合 Xray 反向代理能力，在 NAT/CGNAT 场景下获得更好的可连接性。

## 这个项目现在做了什么

- 容器启动后先拉起 Xray。
- 使用 `tun` 入站（默认网卡名 `xray0`）接管流量。
- 通过策略路由把 qBittorrent 用户（UID）流量导向 `xray0`，不需要在 qB 里额外配 SOCKS。
- 支持通过 Xray `reverse`（bridge 侧）与服务端 `portal` 配合。

## 前置条件

- 宿主机可用 `/dev/net/tun`。
- 容器有 `NET_ADMIN` 权限。
- Docker / Docker Compose 可正常运行。

## 快速部署（推荐）

`docker-compose.yml` 示例：

```yaml
services:
  qb-xray:
    image: ghcr.io/damncrab/qbittorrent-xray:latest
    container_name: qb-xray
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Shanghai
      - WEBUI_PORT=8080
      - TORRENTING_PORT=51413
      - XRAY_QB_UID=1000
    volumes:
      - ./data/config:/config
      - ./data/xray:/etc/xray
      - ./data/downloads:/downloads
    ports:
      - "8080:8080"
      - "51413:51413/tcp"
      - "51413:51413/udp"
```

启动：

```bash
docker compose up -d
```

## Xray 配置说明

- 容器读取 `/etc/xray/config.json`。
- 仓库内 `xray_config.json` 是模板（带环境变量占位符）。
- 生产环境建议你明确挂载自己的 `./data/xray/config.json`，不要依赖默认模板推断。

当前仓库默认是 `tun` 方案，`inbounds` 关键字段建议至少包含：

```json
{
  "tag": "tun-in",
  "port": 0,
  "protocol": "tun",
  "settings": {
    "name": "xray0",
    "MTU": 1500
  }
}
```

## 反向代理（Reverse）定位

这个仓库中的 `reverse.bridges` 是 qB 所在侧（bridge 侧）配置的一部分。  
要让公网入站真正提升可连接性，你还需要在服务端配置对应的 `reverse.portals` 和入站转发策略。

服务端至少要有：

```json
"reverse": {
  "portals": [
    {
      "tag": "portal",
      "domain": "private.qb.tunnel"
    }
  ]
}
```

## qBittorrent 侧建议

- `Network Interface` 设为 `Any interface`（默认更兼容）。
- 不强制要求在 qB 内再配置 SOCKS5（当前方案是透明接管）。
- 监听端口与映射端口保持一致（例如 `51413`）。
- 建议显式设置 `TORRENTING_PORT=51413`；每次启动会按该值同步 qB 监听端口和 Xray 到 qB 的 `redirect` 端口。未设置时会沿用现有 qB 配置端口，若无法识别则回落到 `51413`。

## 如何确认 qB 流量已走 Xray

查看启动日志（应出现 TUN 路由生效日志）：

```bash
docker logs qb-xray | tail -n 80
```

容器内检查策略路由：

```bash
docker exec -it qb-xray sh -lc 'uid=$(id -u abc); ip rule show | grep "$uid-$uid"; ip route get 1.1.1.1 uid $uid'
```

期望结果包含：

- `uidrange 1000-1000 lookup 1001`（或你的 UID）
- `1.1.1.1 dev xray0 table 1001 ...`

下载任务运行中可继续观察：

```bash
docker exec -it qb-xray sh -lc 'ip -s link show xray0'
```

## 常见问题

- `ip route get` 仍走 `eth0`：通常是 UID 规则未命中。优先设置 `XRAY_QB_UID`，然后重建容器。
- 看不到 `xray0`：检查 `/dev/net/tun` 映射和 `NET_ADMIN`；必要时临时用 `privileged: true` 排查。
- “经过 Xray”但不是“全走 VPS”：检查 `routing.rules` 里是否保留了 `direct` 规则（如 `geoip:private`、`geoip:cn`、`geosite:cn`）。

## 手动构建镜像

```bash
docker build -t qb-xray-local .
docker buildx build --platform linux/amd64,linux/arm64 -t your-repo/qb-xray:latest .
```
