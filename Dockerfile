# Imagen mínima: recordatorios Taiga → Discord (solo webhook, sin bot).
FROM alpine:3.20

RUN apk add --no-cache bash curl jq ca-certificates tzdata

ARG SUPERCRONIC_VERSION=0.2.33
ARG TARGETARCH

RUN set -eux; \
  case "$TARGETARCH" in \
    amd64)  SC_ARCH=linux-amd64 ;; \
    arm64)  SC_ARCH=linux-arm64 ;; \
    arm)    SC_ARCH=linux-arm ;; \
    *)      SC_ARCH=linux-amd64 ;; \
  esac; \
  wget -q -O /usr/local/bin/supercronic "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-${SC_ARCH}"; \
  chmod +x /usr/local/bin/supercronic

COPY crontab /etc/supercronic/crontab
COPY scripts/remind.sh /scripts/remind.sh
COPY scripts/export_tasks_html.sh /scripts/export_tasks_html.sh
# Quitar CRLF y BOM UTF-8 (Windows): evita errores de supercronic/bash.
RUN set -eux; \
  for f in /etc/supercronic/crontab /scripts/remind.sh /scripts/export_tasks_html.sh; do \
    tr -d '\r' < "$f" > "${f}.lf" && mv "${f}.lf" "$f"; \
    if [ "$(od -An -tx1 -N3 "$f" | tr -d ' \n')" = "efbbbf" ]; then \
      tail -c +4 "$f" > "${f}.nobom" && mv "${f}.nobom" "$f"; \
    fi; \
  done; \
  chmod +x /scripts/remind.sh /scripts/export_tasks_html.sh

ENV TZ=America/Bogota

CMD ["/usr/local/bin/supercronic", "-passthrough-logs", "/etc/supercronic/crontab"]
