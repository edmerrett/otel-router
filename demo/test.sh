#!/usr/bin/env bash
# Self-contained end-to-end test. Builds the router, runs the demo stack,
# and asserts: fan-out to both sinks for all three signals, rejection of
# unauthenticated senders, and that sinks are unreachable from the source
# network except through the router. Exit 0 = all checks passed.
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

for s in sink-siem sink-app; do
  logs=$(docker compose logs "$s" 2>&1)
  for sig in traces metrics logs; do
    echo "$logs" | grep -q "\"otelcol.signal\": \"$sig\""
    check $? "$s received $sig"
  done
done

docker compose logs gen-noauth 2>&1 | grep -q "Unauthenticated"
check $? "sender without bearer token rejected"

# From the sources network, the sinks must not even resolve.
out=$(docker compose run --rm --no-deps gen-noauth traces \
      --otlp-endpoint sink-siem:4317 --otlp-insecure --duration 2s 2>&1)
echo "$out" | grep -qiE "no such host|produced zero addresses"
check $? "sinks unreachable from source network (router is the only path)"

docker compose down >/dev/null 2>&1

[ "$fail" -eq 0 ] && echo "All checks passed." || echo "Some checks FAILED."
exit "$fail"
