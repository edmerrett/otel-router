# Otel-router

A lightweight container that receives OpenTelemetry (OTLP) data on a single
authenticated endpoint and fans it out to two destinations: a webhook-style
SIEM feed and a native OTLP observability backend.

Services can usually only export OTLP to one place. Point them all here
instead, and this router duplicates the stream to every configured
destination. It is a pinned build of the official
[OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) (contrib
distribution) with a single config file: no custom code to maintain, and
production-grade batching, retries and queueing for free.

```
                             ┌──────────────┐
 your services ──OTLP+auth──▶│  otel-router │──JSON+key──▶ SIEM (webhook, logs)
 (one endpoint)              │  :4317/:4318 │──OTLP+auth──▶ app backend (all signals)
                             └──────────────┘
```

The two destination shapes cover most real backends:

- **Webhook-style** (`otlphttp/siem`): logs posted as plain JSON to one fixed
  URL with an access-key header — the shape of Google SecOps webhook feeds
  and similar HTTPS ingestion endpoints.
- **Native OTLP** (`otlphttp/app`): all three signals to a standard OTLP/HTTP
  base URL with an `Authorization` header.

## Quick start (demo)

Requires Docker. This runs the router, an HTTP echo server standing in for
the webhook SIEM, a real OTLP collector standing in for the app backend, and
generators that fire traces, metrics and logs at the router:

```bash
docker compose up
```

Watch the output: `sink-app` logs all three signals arriving, `webhook-siem`
logs JSON POSTs carrying the access-key header, and `gen-noauth` (which sends
without a bearer token) is rejected with `Unauthenticated`. Ctrl-C to stop.

## Self-contained test

Asserts everything the demo shows, then exits 0 or 1:

```bash
./demo/test.sh
```

Checks: the OTLP destination receives traces, metrics and logs; the webhook
destination receives log records as JSON on its feed URL with the access-key
header — and nothing else (no traces/metrics); a sender without the inbound
bearer token is rejected.

New to OpenTelemetry? [docs/USER_GUIDE.md](docs/USER_GUIDE.md) is a
start-to-finish guide from zero — concepts, first run, secrets, exposure and
operation. For the destination-specific production walkthrough — Claude Teams
managed settings, Harmonic Security, and Google SecOps (webhook feed vs
Bindplane) — see [docs/SETUP.md](docs/SETUP.md).

## Sending sample traffic by hand

`demo/send-sample.sh` posts one example trace, metric and log to the router
with curl (OTLP/JSON), then greps the destination containers' Docker logs to
confirm each arrived. Every run uses a unique marker, so a pass means *this*
run's data landed:

```bash
docker compose up -d
./demo/send-sample.sh
```

It takes an endpoint and token, so the same script smoke-tests a deployed
router — sending works from any machine with curl; the log verification is
skipped when the demo stack isn't running locally:

```bash
./demo/send-sample.sh https://otel.yourdomain.com "$INBOUND_TOKEN"
```

## Running against real destinations

Supply your token and endpoints at runtime — nothing sensitive is baked into
the image. Keep secrets out of your shell history and git by putting them in a
gitignored `.env` file and loading it with `--env-file`:

```bash
cp .env.example .env      # then edit .env with your real values
docker build -t otel-router .

docker run -p 4317:4317 -p 4318:4318 --env-file .env otel-router
```

`.env` holds `INBOUND_TOKEN`, `SIEM_ENDPOINT`, `SIEM_API_KEY`, `SIEM_SECRET`,
`APP_ENDPOINT` and `APP_AUTH` (see [.env.example](.env.example)). For
production, source these from a secret manager rather than a file on disk —
see [docs/USER_GUIDE.md](docs/USER_GUIDE.md) chapter 7.

Then point your services' OTLP exporters at the router, sending
`Authorization: Bearer <INBOUND_TOKEN>`:

| Protocol  | Endpoint                |
|-----------|-------------------------|
| OTLP/gRPC | `http://<router>:4317`  |
| OTLP/HTTP | `http://<router>:4318`  |

### Exposing it publicly

The router authenticates senders but ships **without TLS**, so raw telemetry
and tokens would cross the internet in cleartext. If the endpoint is
public, terminate TLS in front of it: a reverse proxy (Caddy, nginx), a cloud
load balancer, or a platform that provides HTTPS (Cloud Run, Fly.io). Only
expose 4318 (OTLP/HTTP) through the proxy unless you need gRPC. Rotate
`INBOUND_TOKEN` like any credential; changing it is a container restart.

### Example source: Claude Code telemetry

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "https://otel.example.com",
    "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Bearer <INBOUND_TOKEN>"
  }
}
```

Set these in Claude Code settings (or org-wide via managed settings for
Teams/Enterprise). See
[monitoring usage](https://code.claude.com/docs/en/monitoring-usage).

## Configuration

Everything lives in [`config/otel-router.yaml`](config/otel-router.yaml).

### Environment variables

| Variable        | Purpose                                               |
|-----------------|-------------------------------------------------------|
| `INBOUND_TOKEN` | Bearer token senders must present to this router      |
| `SIEM_ENDPOINT` | Full webhook feed URL logs are posted to              |
| `SIEM_API_KEY`  | Value of the `X-goog-api-key` header                  |
| `SIEM_SECRET`   | Value of the `X-Webhook-Access-Key` header            |
| `APP_ENDPOINT`  | OTLP/HTTP base URL of the app backend                 |
| `APP_AUTH`      | `Authorization` header value sent to the app backend  |

If a destination authenticates with different header names, rename the keys
under that exporter's `headers:` block in the config.

### Choosing which signals go where

Each signal (traces, metrics, logs) has its own pipeline in the config. A
destination receives a signal only if its exporter is listed in that
pipeline. By default the webhook feed gets logs only and the app backend
gets everything; add or remove exporters per pipeline to change that:

```yaml
pipelines:
  traces:
    exporters: [otlphttp/app]
  metrics:
    exporters: [otlphttp/app]
  logs:
    exporters: [otlphttp/siem, otlphttp/app]
```

### Swapping destination shapes

Both exporters are `otlphttp`; the difference is configuration. If the SIEM
gains a native OTLP endpoint, replace its `logs_endpoint`/`encoding`/
`compression` lines with a plain `endpoint`. For vendor-specific formats
(Splunk HEC, Elastic, etc.) the contrib image already includes the
exporters — swap the block wholesale.

### Adding a third destination

Copy one of the `otlphttp/*` exporter blocks under a new name, add its env
vars, and list it in the pipelines it should receive. Rebuild the image.

## Delivery behaviour

- Destinations are independent: if one is down, the other keeps receiving.
- Each exporter has an in-memory sending queue with retry and backoff; brief
  destination outages are absorbed, but data is not persisted across a
  router restart. If you need durability, add a `file_storage` extension to
  the sending queues.

## Layout

```
Dockerfile               pinned Collector (contrib) image + config
config/otel-router.yaml  the router: one source, auth, two destinations
docker-compose.yml       demo harness (router + webhook sink + OTLP sink + generators)
demo/sink.yaml           OTLP destination used by the demo
demo/test.sh             self-contained end-to-end test
demo/send-sample.sh      curl-based sample traffic sender + delivery check
```
