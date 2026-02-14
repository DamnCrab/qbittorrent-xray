FROM alpine:3.22

ARG TARGETARCH

RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    jq \
    unzip

RUN set -eux; \
    arch=""; \
    case "${TARGETARCH}" in \
      amd64) arch="64" ;; \
      arm64) arch="arm64-v8a" ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}"; exit 1 ;; \
    esac; \
    curl -L -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"; \
    unzip /tmp/xray.zip -d /tmp/xray; \
    install -m 0755 /tmp/xray/xray /usr/bin/xray; \
    rm -rf /tmp/xray /tmp/xray.zip

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/etc/xray"]

ENTRYPOINT ["/entrypoint.sh"]
