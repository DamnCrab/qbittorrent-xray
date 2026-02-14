# qbittorrent-xray

仓库已拆分为两个独立子项目：

- `client/`：qBittorrent + Xray 客户端容器（TUN 透明接管）
- `server/`：Xray 服务端容器（双用户 + REALITY/XHTTP + reverse portal）

## 快速入口

- 客户端文档：`client/README.md`
- 服务端文档：`server/README.md`

## 启动

客户端：

```bash
cd client
docker compose up -d --build
```

服务端：

```bash
cd server
docker compose up -d --build
```
