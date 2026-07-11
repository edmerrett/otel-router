#!/usr/bin/env bash
# Self-contained end-to-end test. Builds the router, runs the demo stack,
# and asserts: all signals reach the OTLP destination, logs reach the
# webhook-style destination as JSON with the access-key header, and senders
# without the inbound bearer token are rejected. Exit 0 = all checks passed.
set -u
cd "$(dirname "$0")/.."

fail=0
check() {
  if [ "$1" -eq 0 ]; then echo "PASS  $2"; else echo "FAIL  $2"; fail=1; fi
}

echo "Starting stack..."
docker compose down --remove-orphans >/dev/null 2>&1
docker compose up -d --build --quiet-pull >/dev/null 2>&1 || { echo "FAIL  stack failed to start"; exit 1; }
docker compose wait gen-traces gen-metrics gen-logs gen-noauth >/dev/null 2>&1

app=$(docker compose logs sink-backend 2>&1)
for sig in traces metrics logs; do
  echo "$app" | grep -q "\"otelcol.signal\": \"$sig\""
  check $? "OTLP destination (sink-backend) received $sig"
done

hook=$(docker compose logs sink-webhook 2>&1)
echo "$hook" | grep -q '"path": "/v1/ingest"'
check $? "webhook destination received POST on its feed URL"
echo "$hook" | grep -q '"x-webhook-access-key": "demo-webhook-secret"'
check $? "webhook destination received the secret-key header"
echo "$hook" | grep -q '"x-goog-api-key": "demo-api-key"'
check $? "webhook destination received the API-key header"
echo "$hook" | grep -q 'resourceLogs'
check $? "webhook destination received log records as JSON"
echo "$hook" | grep -qE 'resourceSpans|resourceMetrics'
check $((1 - $?)) "webhook destination received logs ONLY (no traces/metrics)"

docker compose logs gen-noauth 2>&1 | grep -q "Unauthenticated"
check $? "sender without bearer token rejected"

docker compose down >/dev/null 2>&1

[ "$fail" -eq 0 ] && echo "All checks passed." || echo "Some checks FAILED."
exit "$fail"
