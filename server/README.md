# Xray Server Container

This folder is an independent server-side subproject.
It does not modify or interfere with the root qbittorrent client container setup.

## What it does

- Creates `/etc/xray/config.json` on first start if missing.
- Auto-generates two users:
  - `normal-user` for regular proxy use
  - `reverse-user` for reverse-proxy bridge use
- Exposes two protocol sets:
  - VLESS + REALITY (`raw`/`tcp`)
  - VLESS + XHTTP + REALITY
- On every start, reads current config and prints:
  - client JSON snippets
  - importable `vless://` URLs

## Start

```bash
cd server
docker compose up -d --build
docker logs -f xray-server
```

Config persistence path:

- `server/data/config.json`

## Main environment variables

- `XRAY_PUBLIC_HOST`: host used in generated import links
- `REALITY_SERVER_NAME`: REALITY `serverNames` value
- `REALITY_TARGET`: REALITY `target` value
- `REVERSE_DOMAIN`: reverse portal/bridge domain
- `REALITY_PORT`, `XHTTP_PORT`: normal-user inbound ports
- `REVERSE_REALITY_PORT`, `REVERSE_XHTTP_PORT`: reverse-user inbound ports
- `REVERSE_PUBLIC_PORT`: public reverse entry port (default `51413`)

## Client-side mapping

When you connect `client/` project to this server:

- use `reverse-user` UUID for bridge outbound
- use `REVERSE_XHTTP_PORT` (or `REVERSE_REALITY_PORT`) as outbound port
- ensure `reverse.bridges[].domain` matches server `REVERSE_DOMAIN`

Check server logs for ready-to-copy JSON snippets and URLs.
