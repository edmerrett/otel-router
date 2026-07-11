#!/usr/bin/env bash
# End-to-end test of the optional TLS mode. Generates a self-signed cert,
# runs the demo stack with demo/tls-compose.yml layered on top, and asserts:
# telemetry is delivered over TLS, HTTPS works from the host with the CA and
# bearer token, plaintext connections are refused, auth is still enforced,
# and the entrypoint fails closed when TLS is enabled without cert files.
# Exit 0 = all checks passed. The plaintext suite is demo/test.sh.
set -u
cd "$(dirname "$0")/.."

fail=0
check() {
  if [ "$1" -eq 0 ]; then echo "PASS  $2"; else echo "FAIL  $2"; fail=1; fi
}

# Self-signed cert, demo only (hence the world-readable key: the router runs
# as uid 10001 and reads it through a bind mount). SANs cover the compose
# hostname (router) and the host-side curl checks (localhost).
echo "Generating demo certificate..."
mkdir -p demo/certs
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout demo/certs/tls.key -out demo/certs/tls.crt \
  -subj "/CN=otel-router-demo" \
  -addext "subjectAltName=DNS:router,DNS:localhost" >/dev/null 2>&1 \
  || { echo "FAIL  could not generate certificate (openssl required)"; exit 1; }
chmod 644 demo/certs/tls.key

compose() { docker compose -f docker-compose.yml -f demo/tls-compose.yml "$@"; }

echo "Starting stack..."
compose down --remove-orphans >/dev/null 2>&1
compose up -d --build --quiet-pull >/dev/null 2>&1 || { echo "FAIL  stack failed to start"; exit 1; }
compose wait gen-traces gen-metrics gen-logs gen-noauth >/dev/null 2>&1

app=$(compose logs sink-app 2>&1)
for sig in traces metrics logs; do
  echo "$app" | grep -q "\"otelcol.signal\": \"$sig\""
  check $? "OTLP destination (sink-app) received $sig over TLS"
done

hook=$(compose logs webhook-siem 2>&1)
echo "$hook" | grep -q 'resourceLogs'
check $? "webhook destination received log records"

# Host-side checks against the published HTTP port.
code=$(curl -s -o /dev/null -w '%{http_code}' --cacert demo/certs/tls.crt \
  -H 'Authorization: Bearer demo-inbound-token' -H 'Content-Type: application/json' \
  -d '{"resourceLogs":[]}' https://localhost:4318/v1/logs)
[ "$code" = "200" ]
check $? "HTTPS request with CA + token accepted (got $code)"

# The same request over plain HTTP must not be served (Go's TLS listener
# answers plaintext with 400, or the connection just fails — never 200).
code=$(curl -s -o /dev/null -w '%{http_code}' \
  -H 'Authorization: Bearer demo-inbound-token' -H 'Content-Type: application/json' \
  -d '{"resourceLogs":[]}' http://localhost:4318/v1/logs)
[ "$code" != "200" ]
check $? "plaintext HTTP request refused while TLS enabled (got $code)"

compose logs gen-noauth 2>&1 | grep -q "Unauthenticated"
check $? "sender with TLS but no bearer token rejected"

compose down >/dev/null 2>&1

# Fail-closed: TLS enabled without cert files must refuse to start. The base
# compose file provides the secrets but no TLS_CERT_FILE/TLS_KEY_FILE.
docker compose run --rm --no-deps -e TLS_ENABLED=true router >/dev/null 2>&1
check $(($? == 0)) "startup refused when TLS_ENABLED=true without cert files"

[ "$fail" -eq 0 ] && echo "All checks passed." || echo "Some checks FAILED."
exit "$fail"
