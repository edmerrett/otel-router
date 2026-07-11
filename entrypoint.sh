#!/bin/sh
# Fail closed on the one thing the router cannot run safely without: the inbound
# bearer token. An empty INBOUND_TOKEN would let the collector accept
# unauthenticated telemetry, so refuse to start rather than expose an open door.
set -e
if [ -z "${INBOUND_TOKEN:-}" ]; then
  echo "otel-router: required environment variable INBOUND_TOKEN is not set; refusing to start" >&2
  exit 1
fi

# Outbound destinations are user-defined in destinations.yaml, so the router
# cannot know which endpoint/credential variables matter. List the ones your
# destinations rely on in REQUIRE_ENV (space-separated) to extend the same
# fail-closed discipline to them, e.g.
#   REQUIRE_ENV="BACKEND_ENDPOINT BACKEND_AUTH WEBHOOK_ENDPOINT"
for v in ${REQUIRE_ENV:-}; do
  eval "val=\${$v:-}"
  if [ -z "$val" ]; then
    echo "otel-router: required environment variable $v (listed in REQUIRE_ENV) is not set; refusing to start" >&2
    exit 1
  fi
done

# Optional TLS: TLS_ENABLED=true layers config/tls.yaml on top of the merged
# config (the collector merges repeated --config flags), putting both OTLP ports
# behind the mounted cert/key. Same fail-closed rule as the token above:
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
