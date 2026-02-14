# qbittorrent-xray

docker build -t qb-xray-local .

``` docker-compose.yml
services:
  qb-xray:
    image: ghcr.io/DamnCrab/qbittorrent-xray:latest
    container_name: qb-xray
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - PUID=1000
      - PGID=100
      - TZ=Asia/Shanghai
      - WEBUI_PORT=8080
    volumes:
      - /home/docker-files/qbittorrent/config:/config
      - /home/docker-files/xray/config.json:/etc/xray/config.json # 挂载你的 xray 配置
      - /srv/mergerfs/fast_pool/omv/downloads:/downloads
    networks:
      macvlan_lan:
        ipv4_address: 192.168.8.240

networks:
  macvlan_lan:
    external: true
```