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
exec /otelcol-contrib "$@"
