# otel-router — complete user guide

A start-to-finish guide for someone who has never used OpenTelemetry before.
By the end you will understand what this service does, have run it on your own
machine, connected a real telemetry source to it, and sent that telemetry to
multiple destinations at once.

Read the chapters in order the first time. Later, use the table of contents to
jump back to what you need.

## Table of contents

1. [What problem this solves](#chapter-1--what-problem-this-solves)
2. [OpenTelemetry in five minutes](#chapter-2--opentelemetry-in-five-minutes)
3. [How this router works](#chapter-3--how-this-router-works)
4. [Install the tools you need](#chapter-4--install-the-tools-you-need)
5. [Run the demo (your first success)](#chapter-5--run-the-demo-your-first-success)
6. [Read the config file](#chapter-6--read-the-config-file)
7. [Handle your secrets safely](#chapter-7--handle-your-secrets-safely)
8. [Run the router with real destinations](#chapter-8--run-the-router-with-real-destinations)
9. [Expose the router to the internet](#chapter-9--expose-the-router-to-the-internet)
10. [Connect a telemetry source (Claude)](#chapter-10--connect-a-telemetry-source-claude)
11. [Watch the data flow](#chapter-11--watch-the-data-flow)
12. [Operate it day to day](#chapter-12--operate-it-day-to-day)
13. [Troubleshooting](#chapter-13--troubleshooting)
14. [Glossary](#chapter-14--glossary)

---

## Chapter 1 — What problem this solves

Modern software emits **telemetry**: a running stream of data about what it is
doing. Errors, timings, events, counts. Tools that produce telemetry usually
let you send it to exactly **one** place.

That is a problem when two different teams need the same data. A security team
wants it in their SIEM (their security monitoring system). An engineering team
wants it in their observability platform. The source will only point at one
address.

**otel-router solves this by being that one address.** Your tools send their
telemetry to the router, and the router copies every piece of it to as many
destinations as you configure. One inbound stream, many outbound copies. This
pattern is called **fan-out**.

```
                        ┌──────────────┐
 your tools ───────────▶│  otel-router │───────────▶ destination A (e.g. a SIEM)
 (one address)          │              │───────────▶ destination B (e.g. an app backend)
                        └──────────────┘
```

The router is not custom software. It is a thin, pinned build of the official
**OpenTelemetry Collector** with one configuration file. You get battle-tested
batching, retries, and queuing without writing or maintaining any code.

---

## Chapter 2 — OpenTelemetry in five minutes

You do not need to be an expert, but a handful of words will appear constantly.
Learn these six and everything else follows.

- **Telemetry** — data a program emits about itself while running.
- **OpenTelemetry (OTel)** — an open industry standard for how that data is
  shaped and transmitted, so any tool can talk to any backend. Think of it as a
  common language.
- **Signal** — a category of telemetry. There are three:
  - **Logs** — timestamped event records ("user did X", "error Y happened").
  - **Metrics** — numbers measured over time (request count, memory used).
  - **Traces** — the path of a single operation as it moves through a system.
- **OTLP** — the OpenTelemetry Protocol. The actual wire format used to send
  signals over the network. It comes in two transports:
  - **OTLP/HTTP** — sent as HTTP POST requests (port 4318 by convention). Can
    carry the body as protobuf (compact binary) or JSON (human-readable).
  - **OTLP/gRPC** — sent over gRPC (port 4317). More efficient, less readable.
  The router accepts both. If you have a choice and want to *read* the data
  while testing, use OTLP/HTTP with JSON.
- **Collector** — a standalone program that receives telemetry, optionally
  processes it, and sends it onward. otel-router is a Collector with a specific
  config.
- **Receiver / Exporter / Pipeline** — the three parts of a Collector's config:
  - A **receiver** takes data *in* (our router's receiver listens for OTLP).
  - An **exporter** sends data *out* to one destination.
  - A **pipeline** connects them for one signal: "logs come in this receiver,
    go out these exporters". Fan-out is simply a pipeline with more than one
    exporter.

That is the whole vocabulary. Chapter 6 shows these words as real config.

---

## Chapter 3 — How this router works

The router does exactly four things:

1. **Receives** OTLP on ports 4317 (gRPC) and 4318 (HTTP).
2. **Authenticates** every inbound request. A sender must present the header
   `Authorization: Bearer <token>`. No token, no entry. This stops strangers
   pushing junk (or worse) into your pipelines once the router is on the
   internet.
3. **Batches** the telemetry so destinations receive tidy groups rather than a
   flood of tiny requests.
4. **Fans out** to the destinations you define. You list as many as you like in
   `config/destinations.yaml`, and each chooses which signals it receives. The
   shipped file includes two examples that cover the two shapes you meet in the
   real world:
   - **`otlphttp/webhook`** is a *webhook-style* destination. Logs only, posted
     as plain JSON to one fixed URL, authenticated with header keys. This
     matches Google SecOps webhook feeds and similar HTTPS ingestion endpoints.
   - **`otlphttp/backend`** is a *native OTLP* destination. All three signals,
     sent to a standard OTLP endpoint with a bearer/authorization header. This
     matches observability platforms and Harmonic Security's OTLP endpoint.

   Neither example is special: rename, duplicate, or delete them to match your
   own destinations.

Every address and every secret is supplied at runtime through **environment
variables**. Nothing sensitive is written into the config files or baked into
the container image. This is central to keeping your credentials safe, and
Chapter 7 is devoted to it.

---

## Chapter 4 — Install the tools you need

You need three things. Install whichever you are missing.

**1. Docker** — runs the router as a container.
Install Docker Desktop (macOS/Windows) or Docker Engine (Linux) from
<https://docs.docker.com/get-docker/>. Verify:

```bash
docker --version
```

**2. openssl** — generates secure random tokens. Almost always already
present. Verify:

```bash
openssl version
```

**3. ngrok** — *(only for the internet-exposure step in Chapter 9)*. Gives your
local router a temporary public HTTPS address so a cloud service can reach it.
Create a free account at <https://ngrok.com>, install the agent, then connect
it once with the authtoken from your ngrok dashboard:

```bash
ngrok config add-authtoken <your-authtoken>
```

You do not need Go, Node, Python, or any OpenTelemetry SDK. The router is a
container; you only orchestrate it.

---

## Chapter 5 — Run the demo (your first success)

Before touching real credentials or the internet, prove the router works on
your machine. The repository ships a self-contained demo: the router plus two
fake destinations plus fake telemetry, all local.

**Step 1 — get the code.**

```bash
git clone https://github.com/edmerrett/otel-router
cd otel-router
```

**Step 2 — run the automated end-to-end test.**

```bash
./demo/test.sh
```

This builds the image, starts everything, fires sample traces/metrics/logs
through the router, and checks they arrive correctly. You should see a list of
`PASS` lines ending in `All checks passed.` Among other things it proves:

- all three signals reach the native-OTLP destination,
- logs (and only logs) reach the webhook destination, as JSON with the right
  header keys,
- a sender with **no** token is rejected.

If that passes, the router is sound on your machine. If it does not, jump to
[Chapter 13](#chapter-13--troubleshooting).

**Step 3 — watch it live (optional).** To see the data with your own eyes
rather than through the test's assertions:

```bash
docker compose up          # Ctrl-C to stop
```

Watch the `sink-webhook` and `sink-backend` containers log the telemetry arriving.
When done:

```bash
docker compose down
```

You have now run a working OpenTelemetry fan-out. Everything from here is
swapping the fakes for real things.

---

## Chapter 6 — Read the config file

The config is split across two files that the collector merges at startup.
You rarely touch the first and regularly touch the second.

**`config/base.yaml`** is the fixed core: how telemetry comes in and is
authenticated. With Chapter 2's vocabulary it reads plainly:

```yaml
extensions:
  bearertokenauth/inbound:          # the inbound guard
    token: ${env:INBOUND_TOKEN}     # value comes from an env var, not the file

receivers:
  otlp:                             # take OTLP in...
    protocols:
      grpc: { endpoint: 0.0.0.0:4317, auth: { authenticator: bearertokenauth/inbound } }
      http: { endpoint: 0.0.0.0:4318, auth: { authenticator: bearertokenauth/inbound } }

processors:
  batch: {}                         # group before sending

service:
  extensions: [bearertokenauth/inbound, health_check]
  # No pipelines here: destinations.yaml supplies them.
```

**`config/destinations.yaml`** is where you say where telemetry goes. This is
the file you edit. It defines one exporter per destination and wires them into
per-signal pipelines:

```yaml
exporters:
  otlphttp/webhook:                    # example destination: webhook-style
    logs_endpoint: ${env:WEBHOOK_ENDPOINT}
    encoding: json
    headers:
      X-goog-api-key:       ${env:WEBHOOK_API_KEY}
      X-Webhook-Access-Key: ${env:WEBHOOK_SECRET}
  otlphttp/backend:                    # example destination: native OTLP
    endpoint: ${env:BACKEND_ENDPOINT}
    encoding: json                     # some backends require this; see note below
    compression: none                  # ...and this
    headers:
      Authorization: ${env:BACKEND_AUTH}

service:
  pipelines:                        # wire receivers -> exporters per signal
    traces:  { receivers: [otlp], processors: [batch], exporters: [otlphttp/backend] }
    metrics: { receivers: [otlp], processors: [batch], exporters: [otlphttp/backend] }
    logs:    { receivers: [otlp], processors: [batch], exporters: [otlphttp/webhook, otlphttp/backend] }
```

The pipelines here reference the `otlp` receiver and `batch` processor from
`base.yaml`; the merge makes them one config. Four things to notice, because
you will change them later:

- **Add or remove a destination** by adding or deleting an exporter block and
  listing it in the pipelines it should feed. There can be as many as you want.
- **Every `${env:...}` is a value filled in at runtime.** The file names the
  secrets; it never contains them. Header names are whatever your destination
  expects, so edit them freely.
- **The `pipelines` block decides who gets what.** `logs` lists both example
  exporters, so both receive logs. `traces` and `metrics` list only
  `otlphttp/backend`, so the webhook destination never sees them.
- **A destination dictates its wire format.** An OTLP/HTTP exporter defaults to
  **protobuf, gzip-compressed** — smaller and faster, and what most backends
  want. Some destinations only accept **OTLP/JSON, uncompressed** and reject the
  default; for those, set `encoding: json` and `compression: none` on that
  exporter (as shown above). The symptom of getting this wrong is telemetry that
  leaves the sender with a `200` but never lands: the router accepts it, then the
  destination rejects the forwarded request with **`415`** (wrong encoding) or
  **`400`** (won't accept gzip). See Chapter 13.

---

## Chapter 7 — Handle your secrets safely

This chapter is the most important one. The router touches four kinds of
secret, and mishandling any of them is how leaks happen.

**The secrets involved:**

| Secret            | What it protects                                          |
|-------------------|----------------------------------------------------------|
| `INBOUND_TOKEN`   | The router's front door. Anyone with it can push data in.|
| `WEBHOOK_API_KEY`    | Your Google Cloud API key for the SecOps feed.           |
| `WEBHOOK_SECRET`     | Your SecOps feed's secret key.                            |
| `BACKEND_AUTH`        | Your credential for the app/Harmonic destination.        |

**Rule 1 — generate the inbound token from real randomness.** Never invent it
by hand. Use:

```bash
openssl rand -hex 32
```

This gives 256 bits of entropy as a 64-character hex string. That is the value
of `INBOUND_TOKEN`, and the same string goes into every sender's
`Authorization: Bearer ...` header.

**Rule 2 — keep secrets out of the config file and the image.** The design
already does this: every credential is an `${env:...}` reference. Do not
"simplify" by pasting a real value into `config/destinations.yaml`, because that
file is in git and would leak the secret to everyone with repo access.

**Rule 3 — never commit secrets to git.** The safe pattern is an environment
file that git ignores. Create a file called `.env` (the repo's `.gitignore`
already excludes it) from the provided template:

```bash
cp .env.example .env
# edit .env, fill in your real values
```

Then pass it to Docker with `--env-file` instead of typing secrets on the
command line:

```bash
docker run -d --name otel-router -p 4318:4318 --env-file .env otel-router
```

This keeps secrets out of two dangerous places at once: your git history and
your shell history.

**Rule 4 — prefer a real secret store in production.** Environment variables
are convenient but readable by anyone who can run `docker inspect` on the
container or read `/proc/<pid>/environ` on the host. For anything beyond
testing, source the values from your platform's secret manager:

- Docker Swarm / Compose: Docker **secrets** (mounted as files).
- Kubernetes: a **Secret** surfaced as env vars or mounted files.
- Cloud: AWS Secrets Manager, GCP Secret Manager, Vault, etc., injected at
  deploy time.

The goal is the same: the secret exists only in the store and in the running
process, never on disk in your project and never in version control.

**Rule 5 — always use HTTPS for destinations, and never expose the router
without TLS.** The `Authorization` header and the raw telemetry travel in the
request. Over plain HTTP they are readable by anyone on the path. So:

- `WEBHOOK_ENDPOINT` and `BACKEND_ENDPOINT` must be `https://` URLs in production.
- The router serves plaintext by default. When you expose it (Chapter 9),
  either something in front of it provides HTTPS (ngrok for testing; a load
  balancer or reverse proxy in production), or you enable the router's own
  TLS mode (`TLS_ENABLED=true` plus a mounted cert/key — see Chapter 9).

**Rule 6 — rotate on a schedule, and immediately if a secret may have leaked.**
Rotation is covered in Chapter 12. The short version: generate a new value,
update the store and every sender, restart the router.

---

## Chapter 8 — Run the router with real destinations

Now point the router at real backends. You will need, from your destination
providers:

- the webhook feed URL, API key, and secret for the SIEM (see
  [SETUP.md](SETUP.md) for the exact Google SecOps steps),
- the OTLP endpoint and auth header for the app backend (for Harmonic
  Security, from your Harmonic console — see [SETUP.md](SETUP.md)).

**Step 1 — create your `.env`** (per Chapter 7):

```bash
cp .env.example .env
```

Edit it to look like this, with your real values:

```bash
INBOUND_TOKEN=<output of: openssl rand -hex 32>
WEBHOOK_ENDPOINT=https://<region>-chronicle.googleapis.com/.../feeds/<id>:importPushLogs
WEBHOOK_API_KEY=<your Google Cloud API key>
WEBHOOK_SECRET=<your feed secret>
BACKEND_ENDPOINT=https://<your app backend OTLP base URL>
BACKEND_AUTH=Bearer <your app backend token>
```

**Step 2 — build and run:**

```bash
docker build -t otel-router .
docker run -d --name otel-router -p 4318:4318 -p 4317:4317 --env-file .env otel-router
```

**Step 3 — confirm it started cleanly:**

```bash
docker logs otel-router | grep "Everything is ready"
```

**Step 4 — smoke-test locally before involving the internet or real senders:**

```bash
./demo/send-sample.sh
```

With the demo stack not running, this sends one trace, metric, and log to
`localhost:4318` and tells you to check your real destinations for
`service.name=sample-sender`. A `200` on each send means the router accepted
and forwarded them. Look in your SIEM and app backend for the sample.

If a send returns `401`, your `INBOUND_TOKEN` and the token the script uses do
not match (the script defaults to the demo token; pass yours as the second
argument: `./demo/send-sample.sh http://localhost:4318 "$INBOUND_TOKEN"`).

---

## Chapter 9 — Expose the router to the internet

A cloud telemetry source (like Claude) cannot reach `localhost`. The router
needs a public HTTPS address. For **testing**, ngrok is the fastest way. For
**production**, use a proper host with TLS.

### Testing: ngrok

With the router running locally on 4318:

```bash
ngrok http 4318
```

ngrok prints a **Forwarding** line like
`https://ab12-34-56-78-90.ngrok-free.app -> http://localhost:4318`. That HTTPS
URL is now your router's public base address, and ngrok provides the TLS. Leave
this terminal open; the tunnel lives only as long as the process.

Test the public path end to end (swap in your URL and token):

```bash
curl -i -X POST https://<your-ngrok-subdomain>.ngrok-free.app/v1/logs \
  -H "Authorization: Bearer <INBOUND_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"ngrok-test"}}]},"scopeLogs":[{"logRecords":[{"severityText":"INFO","body":{"stringValue":"hello via ngrok"}}]}]}]}'
```

A `200` with `{"partialSuccess":{}}` means the full chain works: internet →
ngrok → router → auth passed → forwarded. Note the URL is the **base** address
with `/v1/logs` appended; senders that take a base URL should be given the base
only.

Two ngrok caveats: the free URL **changes every restart** (update your sender
when it does), and ngrok's free tier is for testing, not production traffic.

### Production: a real host with TLS

For anything lasting, run the container on a host or platform that provides
HTTPS in front of it:

- A platform with built-in TLS: Google Cloud Run, Fly.io, Render.
- A VM with a reverse proxy (Caddy or nginx) terminating TLS and forwarding to
  container port 4318.
- A cloud load balancer with a managed certificate.

Expose only port **4318** (OTLP/HTTP) publicly unless a sender specifically
needs gRPC. Everything from Chapter 7 Rule 5 applies: no TLS, no public
exposure.

### Alternative: let the router terminate TLS itself

If nothing in front of the router can provide HTTPS — or your load balancer
wants HTTPS targets (an AWS ALB with an HTTPS target group, for example) —
enable the router's built-in TLS instead:

```bash
TLS_ENABLED=true
TLS_CERT_FILE=/certs/tls.crt   # container paths; mount the PEM files in
TLS_KEY_FILE=/certs/tls.key
```

Both OTLP ports then serve TLS, and startup fails closed if the cert or key
is missing. Behind an ALB HTTPS target group a self-signed certificate is
sufficient (the ALB does not validate target certificates); for direct client
exposure use a certificate the clients trust. `.env.example` has a
self-signed generation one-liner, and `demo/tls-test.sh` shows the whole
thing working end to end. The health port (13133) stays plain HTTP, so ECS
and ALB health checks keep working unchanged.

---

## Chapter 10 — Connect a telemetry source (Claude)

With a public HTTPS address and a token, point a source at it. Claude Code /
Cowork is the worked example; any OTLP source follows the same shape.

For a Claude Teams or Enterprise organisation, an admin sets this org-wide in
**claude.ai/admin-settings/claude-code → Managed settings**:

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/json",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "https://<your-router-address>",
    "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Bearer <INBOUND_TOKEN>"
  }
}
```

Field notes, because these are the common mistakes:

- **`OTEL_EXPORTER_OTLP_ENDPOINT` is the base URL** — no `/v1/logs` suffix. The
  exporter appends the signal path itself.
- **`OTEL_EXPORTER_OTLP_HEADERS` uses `=`**, and the value must include the
  word `Bearer` and a space: `Authorization=Bearer <token>`. A colon, or the
  token without `Bearer `, will fail auth.
- **`http/json` and `http/protobuf` both work.** JSON is readable on the wire
  (nice while testing); protobuf is more compact. Pick either.
- **Enable the switches.** Endpoint and header alone do nothing if telemetry is
  not turned on: `CLAUDE_CODE_ENABLE_TELEMETRY=1` and the exporter variables
  must be set.
- **A privacy decision:** prompt and tool *content* is redacted by default.
  Turning it on (`OTEL_LOG_USER_PROMPTS` and friends) sends that content to
  **every** destination. Decide deliberately, especially while testing against
  a public endpoint.

See [SETUP.md](SETUP.md) for the full production walkthrough including the
Harmonic and SecOps specifics.

---

## Chapter 11 — Watch the data flow

Three views, each answering a different question. Use them together to pinpoint
any problem.

**1. Is the source sending at all?** If you are behind ngrok, open its live
request inspector:

```
http://127.0.0.1:4040
```

Every request through the tunnel appears here instantly, with full headers and
body. You see the `POST /v1/logs`, the `Authorization` header, and the payload
before auth or forwarding matters. This is the single best "is anything
happening" view.

**2. Is the router healthy?** Tail its logs for auth rejections and export
errors:

```bash
docker logs -f otel-router
```

Note: by default this shows lifecycle and errors, **not** the telemetry
payloads (the router has no debug exporter in its pipelines). Silence plus
`200`s upstream means healthy.

**3. Did the data reach the destination?** Check the destination itself — your
SIEM's log search, your app backend's UI, or (while testing) the receiving
service you pointed at.

**Reading them together:**

- Nothing in the ngrok inspector → the source is not sending. Re-check the
  source's config; test with a plain `claude` CLI session as a control.
- Requests in the inspector but `401` in the router logs → the auth header is
  wrong (format or value).
- `200`s everywhere but nothing at the destination → a forwarding/destination
  problem (wrong endpoint, destination rejecting the payload, or a test
  endpoint's request cap reached).

---

## Chapter 12 — Operate it day to day

**Rotate a secret.** For the inbound token:

1. Generate a new one: `openssl rand -hex 32`.
2. Update it in your secret store / `.env`.
3. Update every sender's `Authorization` header to match.
4. Restart the router: `docker restart otel-router`.

With a single shared token there is a brief window where old senders are
rejected until updated, so rotate in a quiet period. Rotating a SecOps feed
secret invalidates the old one immediately — update the router in the same
change. Rotate on a schedule, and at once if a value may have leaked.

**Change which destination gets which signal.** Edit the `pipelines` block in
`config/destinations.yaml` (Chapter 6), then rebuild the image. Example: to send
metrics to the SIEM too, add `otlphttp/webhook` to the `metrics` pipeline's
`exporters` list.

**Add a third destination.** Copy one of the `otlphttp/*` exporter blocks under
a new name, give it its own `${env:...}` variables, list it in the pipelines it
should receive, add the new variables to your `.env`, and rebuild.

**Change a destination's auth header name.** If a backend wants, say, `api-key`
instead of `Authorization`, rename the key under that exporter's `headers:`
block and rebuild.

**Upgrade the Collector.** The image is pinned (e.g. `0.156.0`) on purpose.
When you upgrade, bump the tag in the `Dockerfile`, read that release's notes,
rebuild, and re-run `./demo/test.sh` before deploying.

**Understand delivery guarantees.** Each exporter has a retry queue, so brief
destination outages are absorbed and the two destinations fail independently.
The queue is in memory, so a router restart drops whatever is queued. If you
need durability across restarts, add a `file_storage` extension to the sending
queues.

---

## Chapter 13 — Troubleshooting

| Symptom                                   | Likely cause and fix                                                                 |
|-------------------------------------------|--------------------------------------------------------------------------------------|
| `./demo/test.sh` fails to start the stack | Docker not running, or ports 4317/4318 already in use. Start Docker; free the ports. |
| Sender gets `401 Unauthenticated`         | Token mismatch or malformed header. Value must be `Bearer <token>`, `=` not `:` in Claude's `OTEL_EXPORTER_OTLP_HEADERS`, no stray spaces. |
| Sender gets `400` with a JSON parse error | The request body is malformed JSON, not an auth or transport problem. The request reached the router fine. |
| Sender gets `404`                         | A path was appended to the endpoint. Give the **base** URL; the exporter adds `/v1/...`. |
| `200`s but nothing at the destination     | The router accepted the data but the destination rejected the forwarded request. `docker logs otel-router` shows the real status. **`415`** → the destination wants OTLP/JSON: set `encoding: json` on that exporter. **`400`** on valid data → it won't accept gzip: set `compression: none`. Some backends need both. Otherwise: wrong endpoint, or a test endpoint (e.g. webhook.site) hit its request cap. |
| Router container exits immediately        | A required env var is unset. `docker logs otel-router` names the missing `${env:...}`. Check your `.env`/`--env-file`. |
| Nothing appears from Claude Cowork        | Cowork telemetry export is not documented by Anthropic and may not emit. Run a plain `claude` CLI session as a control; if the CLI works and Cowork does not, the source is the gap, not your router. |
| ngrok URL stopped working                 | The free URL changes on every restart. Update the sender to the new URL.             |

---

## Chapter 14 — Glossary

- **Bearer token** — a shared secret string sent in the `Authorization` header
  as `Bearer <token>`. Whoever holds it is trusted. Treat it like a password.
- **Collector** — the OpenTelemetry program that receives, processes, and sends
  telemetry. otel-router is a Collector plus a small amount of configuration.
- **Exporter** — the config component that sends telemetry out to one
  destination.
- **Fan-out** — copying one inbound stream to multiple destinations.
- **Metric / Log / Trace** — the three signal types (see Chapter 2).
- **OTLP** — OpenTelemetry Protocol, the wire format. `/HTTP` (port 4318) or
  `/gRPC` (port 4317).
- **Pipeline** — the per-signal wiring from receivers to exporters.
- **Receiver** — the config component that takes telemetry in.
- **SIEM** — Security Information and Event Management: a security team's system
  for collecting and analysing logs and events.
- **Signal** — a category of telemetry (logs, metrics, or traces).
- **TLS** — the encryption behind HTTPS. Without it, headers and data are
  readable in transit.
- **Webhook feed** — a destination that accepts data as an HTTP POST of JSON to
  a fixed URL, authenticated with header keys.

---

You now have the full picture: the concepts, a proven local run, real
destinations, a public endpoint, a connected source, and the operational
knowledge to run and secure it. For the destination-specific production
walkthrough (Claude managed settings, Harmonic Security, Google SecOps), read
[SETUP.md](SETUP.md).
