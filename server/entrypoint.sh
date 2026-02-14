#!/usr/bin/env bash
set -euo pipefail

XRAY_BIN="/usr/bin/xray"
XRAY_CONFIG_DIR="${XRAY_CONFIG_DIR:-/etc/xray}"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"

REALITY_PORT="${REALITY_PORT:-443}"
XHTTP_PORT="${XHTTP_PORT:-8443}"
REVERSE_REALITY_PORT="${REVERSE_REALITY_PORT:-2443}"
REVERSE_XHTTP_PORT="${REVERSE_XHTTP_PORT:-9443}"
REVERSE_PUBLIC_PORT="${REVERSE_PUBLIC_PORT:-51413}"

REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.apple.com}"
REALITY_TARGET="${REALITY_TARGET:-${REALITY_SERVER_NAME}:443}"
REVERSE_DOMAIN="${REVERSE_DOMAIN:-private.qb.tunnel}"

XHTTP_MODE="${XHTTP_MODE:-auto}"
XRAY_PUBLIC_HOST="${XRAY_PUBLIC_HOST:-YOUR_SERVER_DOMAIN_OR_IP}"

is_valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

normalize_port() {
  local value="$1"
  local fallback="$2"
  if is_valid_port "$value"; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

random_hex() {
  local byte_count="$1"
  od -An -tx1 -N "$byte_count" /dev/urandom | tr -d ' \n'
}

uri_escape() {
  jq -rn --arg v "$1" '$v|@uri'
}

derive_public_key() {
  local private_key="$1"
  if [ -z "$private_key" ]; then
    printf '\n'
    return
  fi
  "$XRAY_BIN" x25519 -i "$private_key" 2>/dev/null | sed -n 's/^Public key: //p' | head -n1 || true
}

query_json() {
  local query="$1"
  jq -r "$query // empty" "$XRAY_CONFIG"
}

first_line() {
  sed -n '1p'
}

build_reality_url() {
  local uuid="$1"
  local host="$2"
  local port="$3"
  local sni="$4"
  local fp="$5"
  local pbk="$6"
  local sid="$7"
  local flow="$8"
  local name="$9"

  local query
  query="encryption=none&security=reality&type=tcp&sni=$(uri_escape "$sni")&fp=$(uri_escape "$fp")&pbk=$(uri_escape "$pbk")&sid=$(uri_escape "$sid")"
  if [ -n "$flow" ]; then
    query="${query}&flow=$(uri_escape "$flow")"
  fi
  printf 'vless://%s@%s:%s?%s#%s\n' \
    "$uuid" "$host" "$port" "$query" "$(uri_escape "$name")"
}

build_xhttp_url() {
  local uuid="$1"
  local host="$2"
  local port="$3"
  local sni="$4"
  local fp="$5"
  local pbk="$6"
  local sid="$7"
  local path="$8"
  local mode="$9"
  local name="${10}"

  local query
  query="encryption=none&security=reality&type=xhttp&sni=$(uri_escape "$sni")&fp=$(uri_escape "$fp")&pbk=$(uri_escape "$pbk")&sid=$(uri_escape "$sid")&path=$(uri_escape "$path")&mode=$(uri_escape "$mode")"
  printf 'vless://%s@%s:%s?%s#%s\n' \
    "$uuid" "$host" "$port" "$query" "$(uri_escape "$name")"
}

generate_initial_config() {
  local normal_uuid reverse_uuid reality_private_key reality_public_key short_id
  local normal_xhttp_path reverse_xhttp_path

  normal_uuid="$("$XRAY_BIN" uuid)"
  reverse_uuid="$("$XRAY_BIN" uuid)"

  reality_private_key="$("$XRAY_BIN" x25519 | sed -n 's/^Private key: //p' | head -n1)"
  reality_public_key="$(derive_public_key "$reality_private_key")"
  short_id="$(random_hex 8)"
  normal_xhttp_path="/$(random_hex 6)"
  reverse_xhttp_path="/$(random_hex 6)"

  cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "reverse": {
    "portals": [
      {
        "tag": "portal",
        "domain": "${REVERSE_DOMAIN}"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "in-normal-reality",
      "listen": "0.0.0.0",
      "port": ${REALITY_PORT},
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${normal_uuid}",
            "email": "normal-user",
            "flow": "xtls-rprx-vision"
          }
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET}",
          "serverNames": [
            "${REALITY_SERVER_NAME}"
          ],
          "privateKey": "${reality_private_key}",
          "shortIds": [
            "${short_id}"
          ]
        }
      }
    },
    {
      "tag": "in-normal-xhttp",
      "listen": "0.0.0.0",
      "port": ${XHTTP_PORT},
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${normal_uuid}",
            "email": "normal-user"
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET}",
          "serverNames": [
            "${REALITY_SERVER_NAME}"
          ],
          "privateKey": "${reality_private_key}",
          "shortIds": [
            "${short_id}"
          ]
        },
        "xhttpSettings": {
          "path": "${normal_xhttp_path}",
          "mode": "${XHTTP_MODE}"
        }
      }
    },
    {
      "tag": "in-reverse-reality",
      "listen": "0.0.0.0",
      "port": ${REVERSE_REALITY_PORT},
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${reverse_uuid}",
            "email": "reverse-user",
            "flow": "xtls-rprx-vision"
          }
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET}",
          "serverNames": [
            "${REALITY_SERVER_NAME}"
          ],
          "privateKey": "${reality_private_key}",
          "shortIds": [
            "${short_id}"
          ]
        }
      }
    },
    {
      "tag": "in-reverse-xhttp",
      "listen": "0.0.0.0",
      "port": ${REVERSE_XHTTP_PORT},
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${reverse_uuid}",
            "email": "reverse-user"
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET}",
          "serverNames": [
            "${REALITY_SERVER_NAME}"
          ],
          "privateKey": "${reality_private_key}",
          "shortIds": [
            "${short_id}"
          ]
        },
        "xhttpSettings": {
          "path": "${reverse_xhttp_path}",
          "mode": "${XHTTP_MODE}"
        }
      }
    },
    {
      "tag": "in-reverse-external",
      "listen": "0.0.0.0",
      "port": ${REVERSE_PUBLIC_PORT},
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "port": ${REVERSE_PUBLIC_PORT},
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "in-reverse-external"
        ],
        "outboundTag": "portal"
      },
      {
        "type": "field",
        "inboundTag": [
          "in-reverse-reality",
          "in-reverse-xhttp"
        ],
        "outboundTag": "portal"
      }
    ]
  }
}
EOF

  echo "[entrypoint] Generated initial server config: ${XRAY_CONFIG}"
  echo "[entrypoint] normal-user UUID: ${normal_uuid}"
  echo "[entrypoint] reverse-user UUID: ${reverse_uuid}"
  echo "[entrypoint] REALITY public key: ${reality_public_key}"
  echo "[entrypoint] REALITY shortId: ${short_id}"
}

show_client_materials() {
  local normal_uuid reverse_uuid
  local normal_reality_port normal_xhttp_port reverse_reality_port reverse_xhttp_port reverse_public_port
  local server_name short_id private_key public_key
  local normal_path reverse_path xhttp_mode reverse_xhttp_mode reverse_domain
  local fp
  local normal_reality_url normal_xhttp_url reverse_reality_url reverse_xhttp_url

  normal_uuid="$(query_json '[.inbounds[]? | .settings.clients[]? | select(.email=="normal-user") | .id][0]' | first_line)"
  reverse_uuid="$(query_json '[.inbounds[]? | .settings.clients[]? | select(.email=="reverse-user") | .id][0]' | first_line)"

  normal_reality_port="$(query_json '.inbounds[]? | select(.tag=="in-normal-reality") | .port' | first_line)"
  normal_xhttp_port="$(query_json '.inbounds[]? | select(.tag=="in-normal-xhttp") | .port' | first_line)"
  reverse_reality_port="$(query_json '.inbounds[]? | select(.tag=="in-reverse-reality") | .port' | first_line)"
  reverse_xhttp_port="$(query_json '.inbounds[]? | select(.tag=="in-reverse-xhttp") | .port' | first_line)"
  reverse_public_port="$(query_json '.inbounds[]? | select(.tag=="in-reverse-external") | .port' | first_line)"

  server_name="$(query_json '.inbounds[]? | select(.tag=="in-normal-reality") | .streamSettings.realitySettings.serverNames[0]' | first_line)"
  short_id="$(query_json '.inbounds[]? | select(.tag=="in-normal-reality") | .streamSettings.realitySettings.shortIds[0]' | first_line)"
  private_key="$(query_json '.inbounds[]? | select(.tag=="in-normal-reality") | .streamSettings.realitySettings.privateKey' | first_line)"
  public_key="$(derive_public_key "$private_key")"

  normal_path="$(query_json '.inbounds[]? | select(.tag=="in-normal-xhttp") | .streamSettings.xhttpSettings.path' | first_line)"
  reverse_path="$(query_json '.inbounds[]? | select(.tag=="in-reverse-xhttp") | .streamSettings.xhttpSettings.path' | first_line)"
  xhttp_mode="$(query_json '.inbounds[]? | select(.tag=="in-normal-xhttp") | .streamSettings.xhttpSettings.mode' | first_line)"
  reverse_xhttp_mode="$(query_json '.inbounds[]? | select(.tag=="in-reverse-xhttp") | .streamSettings.xhttpSettings.mode' | first_line)"
  reverse_domain="$(query_json '.reverse.portals[0].domain' | first_line)"

  [ -n "$normal_path" ] || normal_path="/"
  [ -n "$reverse_path" ] || reverse_path="/"
  [ -n "$xhttp_mode" ] || xhttp_mode="auto"
  [ -n "$reverse_xhttp_mode" ] || reverse_xhttp_mode="$xhttp_mode"
  [ -n "$reverse_domain" ] || reverse_domain="$REVERSE_DOMAIN"

  fp="${REALITY_FINGERPRINT:-chrome}"

  [ -n "$normal_uuid" ] || normal_uuid="REPLACE_WITH_NORMAL_UUID"
  [ -n "$reverse_uuid" ] || reverse_uuid="REPLACE_WITH_REVERSE_UUID"
  [ -n "$normal_reality_port" ] || normal_reality_port="$REALITY_PORT"
  [ -n "$normal_xhttp_port" ] || normal_xhttp_port="$XHTTP_PORT"
  [ -n "$reverse_reality_port" ] || reverse_reality_port="$REVERSE_REALITY_PORT"
  [ -n "$reverse_xhttp_port" ] || reverse_xhttp_port="$REVERSE_XHTTP_PORT"
  [ -n "$reverse_public_port" ] || reverse_public_port="$REVERSE_PUBLIC_PORT"
  [ -n "$server_name" ] || server_name="$REALITY_SERVER_NAME"
  [ -n "$short_id" ] || short_id="REPLACE_WITH_SHORT_ID"
  [ -n "$public_key" ] || public_key="REPLACE_WITH_PUBLIC_KEY"

  normal_reality_url="$(build_reality_url "$normal_uuid" "$XRAY_PUBLIC_HOST" "$normal_reality_port" "$server_name" "$fp" "$public_key" "$short_id" "xtls-rprx-vision" "normal-reality")"
  normal_xhttp_url="$(build_xhttp_url "$normal_uuid" "$XRAY_PUBLIC_HOST" "$normal_xhttp_port" "$server_name" "$fp" "$public_key" "$short_id" "$normal_path" "$xhttp_mode" "normal-xhttp")"
  reverse_reality_url="$(build_reality_url "$reverse_uuid" "$XRAY_PUBLIC_HOST" "$reverse_reality_port" "$server_name" "$fp" "$public_key" "$short_id" "xtls-rprx-vision" "reverse-reality")"
  reverse_xhttp_url="$(build_xhttp_url "$reverse_uuid" "$XRAY_PUBLIC_HOST" "$reverse_xhttp_port" "$server_name" "$fp" "$public_key" "$short_id" "$reverse_path" "$reverse_xhttp_mode" "reverse-xhttp")"

  cat <<EOF
[entrypoint] =========================
[entrypoint] Xray Server Runtime Info
[entrypoint] config: ${XRAY_CONFIG}
[entrypoint] host for links: ${XRAY_PUBLIC_HOST}
[entrypoint] reverse public port: ${reverse_public_port}
[entrypoint] reverse domain: ${reverse_domain}
[entrypoint] =========================
[entrypoint] One-click URLs
[entrypoint] normal / REALITY:
${normal_reality_url}
[entrypoint] normal / XHTTP:
${normal_xhttp_url}
[entrypoint] reverse / REALITY:
${reverse_reality_url}
[entrypoint] reverse / XHTTP:
${reverse_xhttp_url}
[entrypoint] -------------------------
[entrypoint] Client JSON snippet (normal / REALITY)
{
  "protocol": "vless",
  "settings": {
    "vnext": [
      {
        "address": "${XRAY_PUBLIC_HOST}",
        "port": ${normal_reality_port},
        "users": [
          {
            "id": "${normal_uuid}",
            "encryption": "none",
            "flow": "xtls-rprx-vision"
          }
        ]
      }
    ]
  },
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {
      "serverName": "${server_name}",
      "fingerprint": "${fp}",
      "publicKey": "${public_key}",
      "shortId": "${short_id}",
      "spiderX": "/"
    }
  }
}
[entrypoint] -------------------------
[entrypoint] Client JSON snippet (normal / XHTTP / reality)
{
  "protocol": "vless",
  "settings": {
    "vnext": [
      {
        "address": "${XRAY_PUBLIC_HOST}",
        "port": ${normal_xhttp_port},
        "users": [
          {
            "id": "${normal_uuid}",
            "encryption": "none"
          }
        ]
      }
    ]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "realitySettings": {
      "serverName": "${server_name}",
      "fingerprint": "${fp}",
      "publicKey": "${public_key}",
      "shortId": "${short_id}",
      "spiderX": "/"
    },
    "xhttpSettings": {
      "path": "${normal_path}",
      "mode": "${xhttp_mode}"
    }
  }
}
[entrypoint] -------------------------
[entrypoint] Client JSON snippet (reverse / REALITY)
{
  "protocol": "vless",
  "settings": {
    "vnext": [
      {
        "address": "${XRAY_PUBLIC_HOST}",
        "port": ${reverse_reality_port},
        "users": [
          {
            "id": "${reverse_uuid}",
            "encryption": "none",
            "flow": "xtls-rprx-vision"
          }
        ]
      }
    ]
  },
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {
      "serverName": "${server_name}",
      "fingerprint": "${fp}",
      "publicKey": "${public_key}",
      "shortId": "${short_id}",
      "spiderX": "/"
    }
  }
}
[entrypoint] -------------------------
[entrypoint] Client JSON snippet (reverse bridge / XHTTP / reality)
{
  "reverse": {
    "bridges": [
      {
        "tag": "bridge",
        "domain": "${reverse_domain}"
      }
    ]
  },
  "outbounds": [
    {
      "tag": "vps-out",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${XRAY_PUBLIC_HOST}",
            "port": ${reverse_xhttp_port},
            "users": [
              {
                "id": "${reverse_uuid}",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "serverName": "${server_name}",
          "fingerprint": "${fp}",
          "publicKey": "${public_key}",
          "shortId": "${short_id}",
          "spiderX": "/"
        },
        "xhttpSettings": {
          "path": "${reverse_path}",
          "mode": "${reverse_xhttp_mode}"
        }
      }
    }
  ]
}
[entrypoint] =========================
EOF
}

REALITY_PORT="$(normalize_port "$REALITY_PORT" "443")"
XHTTP_PORT="$(normalize_port "$XHTTP_PORT" "8443")"
REVERSE_REALITY_PORT="$(normalize_port "$REVERSE_REALITY_PORT" "2443")"
REVERSE_XHTTP_PORT="$(normalize_port "$REVERSE_XHTTP_PORT" "9443")"
REVERSE_PUBLIC_PORT="$(normalize_port "$REVERSE_PUBLIC_PORT" "51413")"

mkdir -p "$XRAY_CONFIG_DIR"

if [ ! -f "$XRAY_CONFIG" ]; then
  generate_initial_config
else
  echo "[entrypoint] Using existing config: ${XRAY_CONFIG}"
fi

if [ "$XRAY_PUBLIC_HOST" = "YOUR_SERVER_DOMAIN_OR_IP" ]; then
  echo "[entrypoint] WARNING: XRAY_PUBLIC_HOST is not set. Generated links will use placeholder host."
fi

show_client_materials
echo "[entrypoint] Starting Xray..."
exec "$XRAY_BIN" run -c "$XRAY_CONFIG"
