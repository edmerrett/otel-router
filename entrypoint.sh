#!/bin/sh
# Fail closed: refuse to start unless every endpoint and credential is set.
# Without this the collector boots with empty auth headers and forwards
# telemetry to destinations unauthenticated. The inbound guard already fails
# closed on a missing INBOUND_TOKEN (the bearertokenauth extension rejects an
# empty token); this extends the same discipline to the outbound path.
set -e
for v in INBOUND_TOKEN SIEM_ENDPOINT SIEM_API_KEY SIEM_SECRET APP_ENDPOINT APP_AUTH; do
  eval "val=\${$v:-}"
  if [ -z "$val" ]; then
    echo "otel-router: required environment variable $v is not set; refusing to start" >&2
    exit 1
  fi
done

# Optional TLS: TLS_ENABLED=true layers config/tls.yaml over the base config
# (the collector merges repeated --config flags), putting both OTLP ports
# behind the mounted cert/key. Same fail-closed rule as the secrets above:
# TLS requested but unusable must not silently fall back to plaintext.
case "${TLS_ENABLED:-}" in
  [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss])
    for v in TLS_CERT_FILE TLS_KEY_FILE; do
      eval "val=\${$v:-}"
      if [ -z "$val" ]; then
        echo "otel-router: TLS_ENABLED is set but $v is not; refusing to start" >&2
        exit 1
      fi
      if [ ! -r "$val" ]; then
        echo "otel-router: $v=$val is not a readable file; refusing to start" >&2
        exit 1
      fi
    done
    exec /otelcol-contrib "$@" --config /etc/otelcol-contrib/tls.yaml
    ;;
  ""|[Ff][Aa][Ll][Ss][Ee]|0|[Nn][Oo])
    if [ -n "${TLS_CERT_FILE:-}${TLS_KEY_FILE:-}" ]; then
      echo "otel-router: warning: TLS_CERT_FILE/TLS_KEY_FILE set without TLS_ENABLED=true; starting in PLAINTEXT" >&2
    fi
    ;;
  *)
    echo "otel-router: TLS_ENABLED='$TLS_ENABLED' not understood (use true/false); refusing to start" >&2
    exit 1
    ;;
esac
exec /otelcol-contrib "$@"
