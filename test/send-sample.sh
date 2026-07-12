#!/usr/bin/env bash
# Sends one example trace, metric and log to the router over OTLP/HTTP with
# curl, then (if the demo stack is running here) checks the destination
# containers' Docker logs to confirm each one actually arrived.
#
# Shareable: sending needs only curl + openssl; verification needs docker.
#
# Usage: test/send-sample.sh [endpoint] [token]
#   endpoint  router OTLP/HTTP base URL (default http://localhost:4318)
#   token     inbound bearer token. Precedence: arg 2, then $INBOUND_TOKEN,
#             then the demo default. Prefer the env var for real tokens so
#             they don't land in your shell history or `ps` output:
#               INBOUND_TOKEN=... test/send-sample.sh https://router.example.com
set -u
ENDPOINT="${1:-http://localhost:4318}"
TOKEN="${2:-${INBOUND_TOKEN:-demo-inbound-token}}"
MARKER="sample_$(date +%s)"
NOW="$(date +%s)000000000"
RES='{"attributes":[{"key":"service.name","value":{"stringValue":"sample-sender"}}]}'

fail=0
check() {
  if [ "$1" -eq 0 ]; then echo "PASS  $2"; else echo "FAIL  $2"; fail=1; fi
}

send() {
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ENDPOINT/v1/$1" \
         -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$2")
  check "$([ "$code" = "200" ]; echo $?)" "sent $1 (HTTP $code)"
}

echo "Sending sample telemetry ($MARKER) to $ENDPOINT ..."
send traces "{\"resourceSpans\":[{\"resource\":$RES,\"scopeSpans\":[{\"spans\":[{\"traceId\":\"$(openssl rand -hex 16)\",\"spanId\":\"$(openssl rand -hex 8)\",\"name\":\"${MARKER}_span\",\"kind\":1,\"startTimeUnixNano\":\"$NOW\",\"endTimeUnixNano\":\"$NOW\"}]}]}]}"
send metrics "{\"resourceMetrics\":[{\"resource\":$RES,\"scopeMetrics\":[{\"metrics\":[{\"name\":\"${MARKER}_metric\",\"gauge\":{\"dataPoints\":[{\"asDouble\":42,\"timeUnixNano\":\"$NOW\"}]}}]}]}]}"
send logs "{\"resourceLogs\":[{\"resource\":$RES,\"scopeLogs\":[{\"logRecords\":[{\"timeUnixNano\":\"$NOW\",\"severityText\":\"INFO\",\"body\":{\"stringValue\":\"${MARKER}_log hello from sample-sender\"}}]}]}]}"

cd "$(dirname "$0")/.."
if [ -z "$(docker compose ps -q router 2>/dev/null)" ]; then
  echo "Demo stack not running here; skipping Docker log verification."
  echo "Check your destinations for service.name=sample-sender, marker $MARKER."
  exit "$fail"
fi

echo "Verifying delivery via Docker logs ..."
deadline=$((SECONDS + 15))
span=1 metric=1 log=1 hook=1
while [ $SECONDS -lt $deadline ]; do
  app=$(docker compose logs sink-backend 2>/dev/null)
  echo "$app" | grep -q "${MARKER}_span"   && span=0
  echo "$app" | grep -q "${MARKER}_metric" && metric=0
  echo "$app" | grep -q "${MARKER}_log"    && log=0
  docker compose logs sink-webhook 2>/dev/null | grep -q "${MARKER}_log" && hook=0
  [ $((span + metric + log + hook)) -eq 0 ] && break
  sleep 1
done
check $span   "trace arrived at OTLP destination (sink-backend)"
check $metric "metric arrived at OTLP destination (sink-backend)"
check $log    "log arrived at OTLP destination (sink-backend)"
check $hook   "log arrived at webhook destination (sink-webhook)"

[ "$fail" -eq 0 ] && echo "All checks passed." || echo "Some checks FAILED."
exit "$fail"
