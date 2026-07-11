#!/usr/bin/env bash
# Live end-to-end test with real Claude Cowork telemetry.
#
# It stands up the router and two inspectable local destinations, exposes the
# router on a public HTTPS URL, proves the whole path with a synthetic log,
# then WAITS for you to enter a prompt in Claude Cowork and confirms the
# resulting telemetry reached each configured destination.
#
#   1. builds and starts router + app-otlp (native OTLP) + siem-webhook (JSON)
#   2. gets a public URL (ngrok, or your own via PUBLIC_URL=...)
#   3. self-test: sends one synthetic log through the public URL, checks both
#      destinations received it (proves the pipe before involving Cowork)
#   4. prints the exact Claude managed-settings to paste, then waits
#   5. once Cowork telemetry arrives, reports PASS/FAIL per destination with
#      the evidence, and cleans everything up
#
# Env knobs:
#   INBOUND_TOKEN   reuse a token instead of generating one
#   PUBLIC_URL      skip ngrok and use this HTTPS base URL (you manage exposure)
#   WAIT_TIMEOUT    seconds to wait for Cowork telemetry (default 300)
set -u
cd "$(dirname "$0")"
COMPOSE="docker compose -p otel-router-live -f live-compose.yml"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
NGROK_PID=""

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
check() { if [ "$1" -eq 0 ]; then echo "PASS  $2"; else echo "FAIL  $2"; fi; }

cleanup() {
  say "Cleaning up..."
  $COMPOSE down >/dev/null 2>&1
  [ -n "$NGROK_PID" ] && kill "$NGROK_PID" >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

# --- preflight ---------------------------------------------------------------
command -v docker >/dev/null || { echo "docker is required"; exit 1; }
: "${INBOUND_TOKEN:=$(openssl rand -hex 32)}"
export INBOUND_TOKEN
echo "Inbound token: $INBOUND_TOKEN"

# --- 1. bring up the stack ---------------------------------------------------
say "Starting router + destinations..."
$COMPOSE up -d --build --quiet-pull >/dev/null 2>&1 || { echo "stack failed to start"; exit 1; }
# wait for the router to accept connections
for _ in $(seq 1 20); do
  curl -s -o /dev/null "http://localhost:4318/" && break; sleep 1
done

# --- 2. public URL -----------------------------------------------------------
if [ -n "${PUBLIC_URL:-}" ]; then
  ENDPOINT="$PUBLIC_URL"
  echo "Using PUBLIC_URL: $ENDPOINT"
else
  # reuse an existing ngrok tunnel if one is already running, else start one
  if ! curl -s http://127.0.0.1:4040/api/tunnels >/dev/null 2>&1; then
    command -v ngrok >/dev/null || { echo "ngrok not found and no PUBLIC_URL set"; exit 1; }
    say "Starting ngrok tunnel to :4318..."
    ngrok http 4318 --log=stdout >/tmp/otel-router-ngrok.log 2>&1 &
    NGROK_PID=$!
  fi
  for _ in $(seq 1 20); do
    ENDPOINT=$(curl -s http://127.0.0.1:4040/api/tunnels \
      | grep -o '"public_url":"https://[^"]*"' | head -1 | sed 's/.*"\(https:[^"]*\)"/\1/')
    [ -n "${ENDPOINT:-}" ] && break; sleep 1
  done
  [ -n "${ENDPOINT:-}" ] || { echo "could not obtain a public URL from ngrok"; exit 1; }
  echo "Public URL: $ENDPOINT"
fi

# --- 3. self-test: prove the public path before involving Cowork -------------
say "Self-test: sending one synthetic log through the public URL..."
SELF="selftest_$(date +%s)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ENDPOINT/v1/logs" \
  -H "Authorization: Bearer $INBOUND_TOKEN" -H "Content-Type: application/json" \
  -d "{\"resourceLogs\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"selftest\"}}]},\"scopeLogs\":[{\"logRecords\":[{\"body\":{\"stringValue\":\"$SELF\"}}]}]}]}")
check "$([ "$code" = "200" ]; echo $?)" "public URL accepted the log (HTTP $code)"
sleep 3
$COMPOSE logs app-otlp     2>&1 | grep -q "$SELF"; check $? "synthetic log reached app-otlp (native OTLP)"
$COMPOSE logs siem-webhook 2>&1 | grep -q "$SELF"; check $? "synthetic log reached siem-webhook (JSON feed)"
if [ "$code" != "200" ]; then
  echo "Public path is not working; fix that before testing Cowork. See docs/USER_GUIDE.md ch.13."
  exit 1
fi

# --- 4. configure Cowork, then wait for real telemetry -----------------------
cat <<EOF

============================================================================
 Point Claude Cowork at this router. In claude.ai/admin-settings/claude-code
 -> Managed settings, set:

   {
     "env": {
       "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
       "OTEL_LOGS_EXPORTER": "otlp",
       "OTEL_METRICS_EXPORTER": "otlp",
       "OTEL_EXPORTER_OTLP_PROTOCOL": "http/json",
       "OTEL_EXPORTER_OTLP_ENDPOINT": "$ENDPOINT",
       "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Bearer $INBOUND_TOKEN"
     }
   }

 Then ENTER A PROMPT IN CLAUDE COWORK. Waiting up to ${WAIT_TIMEOUT}s for its
 telemetry to arrive... (Ctrl-C to abort)
============================================================================
EOF

# Poll both destinations for Claude-originated telemetry (the self-test used
# service.name "selftest"; Cowork/Claude Code telemetry is identifiable by
# "claude"). Succeeds as soon as it appears; no keypress needed.
app_seen=1; siem_seen=1
deadline=$((SECONDS + WAIT_TIMEOUT))
while [ $SECONDS -lt $deadline ]; do
  $COMPOSE logs app-otlp     2>&1 | grep -qi 'claude' && app_seen=0
  $COMPOSE logs siem-webhook 2>&1 | grep -qi 'claude' && siem_seen=0
  [ $((app_seen + siem_seen)) -eq 0 ] && break
  printf '\r  waiting... %ss left   ' "$((deadline - SECONDS))"
  sleep 3
done
echo

# --- 5. report ---------------------------------------------------------------
say "Result"
check $app_seen  "Claude telemetry reached app-otlp (native OTLP, all signals)"
check $siem_seen "Claude telemetry reached siem-webhook (logs only, JSON)"

if [ $((app_seen + siem_seen)) -ne 0 ]; then
  echo
  echo "No Claude telemetry seen at one or both destinations within ${WAIT_TIMEOUT}s."
  echo "Checks: did you save the managed settings and enter a Cowork prompt?"
  echo "Cowork telemetry export is undocumented by Anthropic - test a plain"
  echo "'claude' CLI session with the same settings as a control (see docs/SETUP.md)."
  exit 1
fi

echo
echo "Evidence (most recent Claude log at each destination):"
echo "-- app-otlp --";     $COMPOSE logs app-otlp     2>&1 | grep -i 'claude' | tail -1
echo "-- siem-webhook --"; $COMPOSE logs siem-webhook 2>&1 | grep -i 'claude' | tail -1
echo
echo "PASS: Cowork telemetry fanned out to both configured destinations."
