# Setup guide: Claude telemetry → otel-router → Harmonic Security + Google SecOps

End-to-end instructions for routing Claude (Teams/Enterprise) agent telemetry
through this router to Harmonic Security and Google SecOps. Researched July
2026; vendor consoles move, so treat exact click paths as approximate and the
cited docs as authoritative.

```
 Claude Code / Cowork ──OTLP+bearer──▶ otel-router ──OTLP+auth──▶ Harmonic (all signals)
 (managed settings)      (public,        │
                          TLS in front)  └──JSON+keys──▶ Google SecOps (logs only)
```

## What the research established

**Harmonic Security natively ingests OpenTelemetry.** Harmonic
[announced OTel support](https://www.harmonic.security/resources/harmonic-now-supports-opentelemetry)
explicitly for AI coding-agent telemetry, with Claude Cowork, Claude Code CLI
and OpenAI Codex covered at launch. Data goes through the same detection
pipeline as their browser/endpoint sources. The endpoint URL, protocol and
auth header are **not publicly documented** (there is no public docs site) —
get them from the Harmonic console or team. Their
[Cowork security guide](https://www.harmonic.security/resources/securing-claude-cowork-a-security-practitioners-guide)
is worth reading regardless: it covers the Claude event types and which
fields (`user_prompt`, `tool_parameters`, `user.email`) you may want to
filter.

**Google SecOps has no native OTLP endpoint.** (Google Cloud's
`telemetry.googleapis.com` OTLP endpoint feeds Cloud Observability, not
SecOps.) Three viable routes, detailed in step 4: a **webhook feed** (what
this router's config targets by default — lightweight, static-key auth,
unofficial for OTLP payloads), a **Bindplane gateway** (Google's documented
OTel path — SecOps is standardising on OTel collectors + Bindplane and
retiring the legacy forwarder by January 2027), and a **first-party SecOps
exporter for the OTel Collector** which Google is
[donating to opentelemetry-collector-contrib](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/46148)
— once that ships in a contrib release, this router can export to SecOps
directly and drop the webhook shape.

## Step 1 — deploy the router

1. Generate the inbound token: `openssl rand -hex 32`. Store it in your
   secret manager; it goes to two places (router env, Claude managed
   settings).
2. Run the container somewhere with a public HTTPS front. Usually that means
   TLS terminates in front — Cloud Run / Fly.io / a load balancer / Caddy,
   forwarding to container port **4318** (OTLP/HTTP is all Claude needs).
   Alternatively the router can serve TLS itself: set `TLS_ENABLED=true`
   with a mounted cert/key (`TLS_CERT_FILE`/`TLS_KEY_FILE`) — handy for an
   ALB HTTPS target group on ECS, where a self-signed cert is sufficient.
3. Set the environment variables (destination values come from steps 3–4):

   | Variable        | Value                                                  |
   |-----------------|--------------------------------------------------------|
   | `INBOUND_TOKEN` | the token from 1.                                      |
   | `BACKEND_ENDPOINT`  | Harmonic OTLP base URL                                 |
   | `BACKEND_AUTH`      | Harmonic auth header value                             |
   | `WEBHOOK_ENDPOINT` | SecOps webhook feed URL (full, copied from console)    |
   | `WEBHOOK_API_KEY`  | Google Cloud API key (`X-goog-api-key`)                |
   | `WEBHOOK_SECRET`   | feed secret key (`X-Webhook-Access-Key`)               |

4. Smoke-test from any machine before wiring anything else up:
   `./test/send-sample.sh https://otel.yourdomain.com "$INBOUND_TOKEN"` —
   expect three `HTTP 200`s; a `401` means the token, a `404`/`502` means
   the proxy wiring.

## Step 2 — point Claude at it

Claude Code telemetry is standard OTLP: metrics plus event logs
(`claude_code.user_prompt`, `tool_result`, `api_request`, `tool_decision`,
etc.); traces exist behind a beta flag. Deploy org-wide from
**claude.ai/admin-settings/claude-code → Managed settings** (Teams and
Enterprise; applies to all users):

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "https://otel.yourdomain.com",
    "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Bearer <INBOUND_TOKEN>"
  }
}
```

Decisions to make deliberately:

- **Content capture.** Prompt and tool content are redacted by default.
  `OTEL_LOG_USER_PROMPTS=1` (and friends) turn them on — that sends prompt
  text to both destinations. Harmonic's pipeline benefits from content;
  decide whether SecOps should hold it too (the router can only drop whole
  signals per destination, not fields — field-level filtering needs a
  `transform` processor added to the SIEM pipeline).
- **Coverage caveat.** OTLP export is documented for the Claude Code CLI.
  Cowork (desktop) and claude.ai/code cloud sessions are not covered by the
  telemetry docs — confirm current status with Anthropic before promising
  SecOps coverage of those agents. (Harmonic's announcement names Cowork,
  suggesting it emits the same telemetry, but Anthropic's docs don't yet.)
- Reference: [Claude Code monitoring docs](https://code.claude.com/docs/en/monitoring-usage).

## Step 3 — Harmonic destination

1. Get the OTLP endpoint URL and auth header from the Harmonic console/team
   (not public).
2. `BACKEND_ENDPOINT` = that base URL. `BACKEND_AUTH` = the header value.
3. If Harmonic's header is not `Authorization`, rename the key under
   `otlphttp/backend.headers` in `config/destinations.yaml` and rebuild.
4. Harmonic receives all three signals by default (it wants the event logs;
   metrics/traces are cheap to include). Trim pipelines in the config if
   they ask for less.

## Step 4 — Google SecOps destination

### Option A: webhook feed (the default this repo ships)

Lightest path; static-key auth; fine for getting events in and searching
them. The payload is OTLP/JSON envelopes, which SecOps does not natively
parse — see the parsing note below.

1. **API key**: Google Cloud console (the project bound to your SecOps
   instance) → APIs & Services → Credentials → Create credentials → API
   key. Restrict it to the **Chronicle API** (enable that API first). This
   is `WEBHOOK_API_KEY`.
2. **Feed**: SecOps console → **Settings → Feeds → Add new**. Name it,
   Source type **Webhook**, pick a log type (see parsing note), Next through
   the optional params, Submit.
3. **Secret**: on the created feed, click **Generate Secret Key** — shown
   once; store it. This is `WEBHOOK_SECRET`.
4. **URL**: feed **Details tab → Endpoint Information** — copy the full
   endpoint URL (shaped like
   `https://<region>-chronicle.googleapis.com/v1alpha/projects/<n>/locations/<loc>/instances/<id>/feeds/<id>:importPushLogs`;
   always copy, never construct). This is `WEBHOOK_ENDPOINT`.
5. Limits worth knowing: 4 MB per request, ~1 MB per log line on push
   feeds; success returns an empty 200.

**Transport compatibility.** The mechanics have been verified from both
ends. The collector's `otlphttp` exporter treats any 2xx with an empty body
as success (checked in the
[exporter source](https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/otlphttpexporter/otlp.go)) —
and an empty 200 is exactly what SecOps webhook feeds return. Tested against
this repo's webhook sink: one log in, exactly one POST out, zero exporter
errors, no retries, even when the sink replies with non-OTLP JSON. On the
SecOps side, webhook feeds accept an arbitrary raw JSON body by design (4 MB
per request, ~1 MB per line; our envelope is a single line). What is NOT
verified is a live SecOps tenant accepting and indexing the payload — run a
30-minute spike with `send-sample.sh` pointed at a real feed before
committing to this route.

**Parsing note.** Each router POST is one OTLP `resourceLogs` JSON envelope
(possibly several Claude events per envelope, thanks to batching). SecOps
will store it raw against your chosen log type; to get proper UDM events
you'll want a **custom log type plus a parser extension or custom parser**
([self-service parser options](https://docs.cloud.google.com/chronicle/docs/event-processing/self-service-parser-options)) —
or accept raw-log search only. JSON auto-extraction helps but works best
with one event per line, which OTLP envelopes are not. If parse fidelity
matters, prefer Option B.

### Option B: Bindplane gateway (Google's documented OTel path)

Bindplane Enterprise "Google Edition" is included with SecOps licensing.
Architecture: this router's SIEM exporter becomes plain OTLP pointing at a
[Bindplane gateway collector](https://docs.cloud.google.com/chronicle/docs/ingestion/use-bindplane-agent)
(it has an [OTLP source](https://docs.bindplane.com/integrations/sources/opentelemetry-otlp)
on 4317/4318), which exports to SecOps via its
[Chronicle exporter](https://github.com/observIQ/bindplane-otel-collector/blob/main/exporter/chronicleexporter/README.md)
using service-account credentials, with proper `log_type` handling and the
supported ingestion API. Config change here: replace the `otlphttp/webhook`
block with a normal `endpoint:`-style OTLP exporter aimed at the gateway
(the README's "Swapping destination shapes" section).

Choose B when you want supported parsing/UDM mapping and service-account
auth instead of static keys. It costs you one more running component.

### Option C: watch for the native exporter

Google's SecOps exporter is an accepted donation to
opentelemetry-collector-contrib. When it appears in a contrib release,
bump this image's pin, swap `otlphttp/webhook` for the new exporter, and
retire the webhook feed. Check the
[tracking issue](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/46148).

**Billing note**: webhook/API ingestion has no separate fee; bytes count
against your SecOps tier's ingestion cap.

## Step 5 — verify end to end

1. `./test/test.sh` locally — proves the image and config are sound.
2. `./test/send-sample.sh https://otel.yourdomain.com "$INBOUND_TOKEN"` —
   the script prints a unique marker (e.g. `sample_1783790961`).
3. **SecOps**: raw log search for the marker (scoped to your feed's log
   type). **Harmonic**: check the console for `service.name=sample-sender`
   activity.
4. Flip managed settings for a pilot group... which doesn't exist yet —
   managed settings are org-wide — so flip it for the org in a quiet window,
   run one Claude Code session, and search both destinations for
   `claude_code.user_prompt` events.
5. Only then announce coverage.

## Operational notes

- **Rotation**: `INBOUND_TOKEN` and `WEBHOOK_SECRET` are static — rotate on a
  schedule (regenerating the feed secret invalidates the old one
  immediately; update the router env in the same change).
- **Delivery**: destination outages are absorbed by in-memory retry queues;
  a router restart drops what's queued. Add `file_storage` if that matters.
- **Independence**: Harmonic and SecOps exporters fail independently — one
  being down never blocks the other.
