#!/usr/bin/env bash
# End-to-end test AND demo of the router: send one of each signal, watch the
# router accept and authenticate it, then see the exact record arrive at each
# of the two destinations. Auto-plays, narrates each stage, and ASSERTS as it
# goes: a missing record prints FAIL and the script exits non-zero. This is the
# local check and the CI check.
#
#   ./test/test.sh
#
# No arguments. Needs docker; uses curl, openssl, and (if present) python3 to
# pretty-print JSON. Cleans up the stack on exit. Set DEMO_PACE=0 to skip the
# inter-stage pauses (CI does this).
set -u
cd "$(dirname "$0")/.."

COMPOSE="docker compose -f test/live-compose.yml -p otel-router-demo"
fail=0

# --- presentation ------------------------------------------------------------
if [ -t 1 ]; then
  B=$(printf '\033[1m'); DIM=$(printf '\033[2m'); R=$(printf '\033[0m')
  GRN=$(printf '\033[32m'); RED=$(printf '\033[31m'); CYN=$(printf '\033[36m'); YEL=$(printf '\033[33m')
else
  B=""; DIM=""; R=""; GRN=""; RED=""; CYN=""; YEL=""
fi

stage() { printf '\n%s%s  %s%s\n' "$B" "$1" "$2" "$R"; }
say()   { printf '  %s\n' "$1"; }
pass()  { printf '  %s✓%s %s\n' "$GRN" "$R" "$1"; }
bad()   { printf '  %s✗ %s%s\n' "$RED" "$1" "$R"; fail=1; }
beat()  { sleep "${DEMO_PACE:-1}"; }
pretty(){ if command -v python3 >/dev/null 2>&1; then python3 -m json.tool 2>/dev/null || cat; else cat; fi; }

cleanup() { printf '\n%sTearing down...%s\n' "$DIM" "$R"; $COMPOSE down >/dev/null 2>&1; }
trap cleanup EXIT INT TERM

command -v docker >/dev/null || { echo "docker is required"; exit 1; }

MARKER="demo_$(date +%s)"
NOW="$(date +%s)000000000"
export INBOUND_TOKEN="$(openssl rand -hex 32)"
RES='{"attributes":[{"key":"service.name","value":{"stringValue":"demo-sender"}}]}'

# --- stage 1: setup ----------------------------------------------------------
stage "STAGE 1" "Start the router and two destinations"
say "${DIM}building image and starting router + backend + webhook...${R}"
$COMPOSE down --remove-orphans >/dev/null 2>&1
$COMPOSE up -d --build --quiet-pull >/dev/null 2>&1 || { bad "stack failed to start"; exit 1; }
for _ in $(seq 1 20); do curl -s -o /dev/null "http://localhost:4318/" && break; sleep 1; done
pass "stack up: router (:4318) -> backend (native OTLP) + webhook (JSON)"
say "${DIM}every request must carry: Authorization: Bearer <token>${R}"
beat

# --- stage 2: send -----------------------------------------------------------
stage "STAGE 2" "Send one trace, one metric, one log (marker=$MARKER)"
send() {
  curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:4318/v1/$1" \
    -H "Authorization: Bearer $INBOUND_TOKEN" -H "Content-Type: application/json" -d "$2"
}
TRACE="{\"resourceSpans\":[{\"resource\":$RES,\"scopeSpans\":[{\"spans\":[{\"traceId\":\"$(openssl rand -hex 16)\",\"spanId\":\"$(openssl rand -hex 8)\",\"name\":\"${MARKER}-span\",\"kind\":1,\"startTimeUnixNano\":\"$NOW\",\"endTimeUnixNano\":\"$NOW\"}]}]}]}"
METRIC="{\"resourceMetrics\":[{\"resource\":$RES,\"scopeMetrics\":[{\"metrics\":[{\"name\":\"${MARKER}-metric\",\"gauge\":{\"dataPoints\":[{\"asDouble\":42,\"timeUnixNano\":\"$NOW\"}]}}]}]}]}"
LOG="{\"resourceLogs\":[{\"resource\":$RES,\"scopeLogs\":[{\"logRecords\":[{\"timeUnixNano\":\"$NOW\",\"severityText\":\"INFO\",\"body\":{\"stringValue\":\"${MARKER}-log hello from otel-router\"}}]}]}]}"

say "${DIM}the log we POST (pretty-printed):${R}"
printf '%s\n' "$LOG" | pretty | sed 's/^/    /'
beat

# --- stage 3: seen (accepted + authenticated) --------------------------------
stage "STAGE 3" "Router receives, authenticates, and accepts"
for pair in "traces:$TRACE" "metrics:$METRIC" "logs:$LOG"; do
  sig="${pair%%:*}"; body="${pair#*:}"
  code=$(send "$sig" "$body")
  if [ "$code" = "200" ]; then pass "$sig accepted (HTTP $code)"; else bad "$sig rejected (HTTP $code)"; fi
done
beat

# --- stage 4: routed & verified ----------------------------------------------
stage "STAGE 4" "Fanned out to both destinations"
# give the batch processor a moment to flush, then poll for the marker
backend=""; webhook=""
for _ in $(seq 1 10); do
  backend=$($COMPOSE logs sink-backend 2>&1)
  webhook=$($COMPOSE logs sink-webhook 2>&1)
  echo "$backend" | grep -q "${MARKER}-log" && echo "$webhook" | grep -q "${MARKER}-log" && break
  sleep 1
done

printf '  %s-> backend%s  (native OTLP, all signals)\n' "$CYN" "$R"
echo "$backend" | grep -q "${MARKER}-span"   && pass "trace  ${MARKER}-span"   || bad "trace not seen at backend"
echo "$backend" | grep -q "${MARKER}-metric" && pass "metric ${MARKER}-metric" || bad "metric not seen at backend"
echo "$backend" | grep -q "${MARKER}-log"    && pass "log    ${MARKER}-log"    || bad "log not seen at backend"

printf '  %s-> webhook%s  (JSON feed, logs only)\n' "$CYN" "$R"
if echo "$webhook" | grep -q "${MARKER}-log"; then
  pass "log    ${MARKER}-log  (POST /v1/ingest)"
  echo "$webhook" | grep -q '"x-goog-api-key"'       && pass "header x-goog-api-key: ${DIM}•••${R}"
  echo "$webhook" | grep -q '"x-webhook-access-key"' && pass "header x-webhook-access-key: ${DIM}•••${R}"
else
  bad "log not seen at webhook"
fi
if echo "$webhook" | grep -qE "${MARKER}-span|${MARKER}-metric"; then
  bad "webhook received traces/metrics (should be logs only)"
else
  pass "no traces/metrics at webhook (correctly filtered)"
fi
beat

# --- stage 5: the door is locked ---------------------------------------------
stage "STAGE 5" "A request with no token is rejected"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:4318/v1/logs" \
  -H "Content-Type: application/json" -d "$LOG")
if [ "$code" != "200" ]; then pass "unauthenticated request refused (HTTP $code)"; else bad "unauthenticated request was ACCEPTED"; fi
beat

# --- summary -----------------------------------------------------------------
printf '\n%s%s%s\n' "$B" "Summary" "$R"
printf '  %-28s%-9s%-9s%-9s\n' "destination" "traces" "metrics" "logs"
cell() { if echo "$1" | grep -q "$2"; then printf '%s✓%s%8s' "$GRN" "$R" ''; else printf '%s✗%s%8s' "$RED" "$R" ''; fi; }
dash() { printf '%s-%s%8s' "$DIM" "$R" ''; }
printf '  %-28s' "backend (all signals)"; cell "$backend" "${MARKER}-span"; cell "$backend" "${MARKER}-metric"; cell "$backend" "${MARKER}-log"; echo
printf '  %-28s' "webhook (logs only)"; dash; dash; cell "$webhook" "${MARKER}-log"; echo

if [ "$fail" -eq 0 ]; then
  printf '\n%s%s All stages passed.%s\n' "$GRN" "$B" "$R"
else
  printf '\n%s%s Some stages FAILED.%s See docs/USER_GUIDE.md ch.13.\n' "$RED" "$B" "$R"
fi
exit "$fail"
