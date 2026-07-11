# Otel-router

A lightweight container that receives OpenTelemetry (OTLP) data on a single
authenticated endpoint and fans it out to two destinations: your SIEM and
your application observability backend.

Services can usually only export OTLP to one place. Point them all here
instead, and this router duplicates the stream to every configured
destination. It is a pinned build of the official
[OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) (contrib
distribution) with a single config file: no custom code to maintain, and
production-grade batching, retries and queueing for free.

```
                             ┌──────────────┐
 your services ──OTLP+auth──▶│  otel-router │──OTLP+auth──▶ SIEM
 (one endpoint)              │  :4317/:4318 │──OTLP+auth──▶ app backend
                             └──────────────┘
```

## Quick start (demo)

Requires Docker. This runs the router, two dummy OTLP sinks standing in for
your SIEM and app backend, and generators that fire traces, metrics and logs
at the router:

```bash
docker compose up
```

Watch the output: the same telemetry appears in the logs of **both**
`sink-siem` and `sink-app`, while `gen-noauth` (which sends without a bearer
token) is rejected with `Unauthenticated`. Ctrl-C to stop.

## Running against real destinations

Build and run the router with your token and endpoints supplied as
environment variables — nothing sensitive is baked into the image:

```bash
docker build -t otel-router .

docker run -p 4317:4317 -p 4318:4318 \
  -e INBOUND_TOKEN="$(openssl rand -hex 32)" \
  -e SIEM_ENDPOINT=https://siem.example.com:4318 \
  -e SIEM_AUTH="Bearer $SIEM_TOKEN" \
  -e APP_ENDPOINT=https://o11y.example.com:4318 \
  -e APP_AUTH="Bearer $APP_TOKEN" \
  otel-router
```

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

| Variable        | Purpose                                              |
|-----------------|------------------------------------------------------|
| `INBOUND_TOKEN` | Bearer token senders must present to this router     |
| `SIEM_ENDPOINT` | OTLP/HTTP base URL of the SIEM                       |
| `SIEM_AUTH`     | `Authorization` header value sent to the SIEM        |
| `APP_ENDPOINT`  | OTLP/HTTP base URL of the app backend                |
| `APP_AUTH`      | `Authorization` header value sent to the app backend |

If a destination authenticates with a different header (e.g. `api-key`),
rename the key under that exporter's `headers:` block in the config.

### Choosing which signals go where

Each signal (traces, metrics, logs) has its own pipeline in the config. A
destination receives a signal only if its exporter is listed in that
pipeline. For example, to send logs to both but keep traces and metrics out
of the SIEM:

```yaml
pipelines:
  traces:
    exporters: [otlphttp/app]
  metrics:
    exporters: [otlphttp/app]
  logs:
    exporters: [otlphttp/siem, otlphttp/app]
```

### Adding a third destination

Copy one of the `otlphttp/*` exporter blocks under a new name, add its env
vars, and list it in the pipelines it should receive. Rebuild the image.

### Non-OTLP destinations

If a destination needs a vendor-specific format or a fixed ingestion URL,
the contrib image already includes the exporters: swap the `otlphttp` block
for the vendor one (Splunk HEC, Elastic, etc.), or use `otlphttp`'s
`logs_endpoint` + `encoding: json` to post to an HTTPS ingestion feed.

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
docker-compose.yml       demo harness (router + 2 sinks + generators)
demo/sink.yaml           dummy destination used by the demo
```
