# Security model

How otel-router authenticates traffic, where the secrets live, and the limits
of the current design. Read alongside [USER_GUIDE.md](USER_GUIDE.md) chapter 7,
which covers the day-to-day handling.

## Authentication at a glance

| Direction | Mechanism | Failure mode |
|-----------|-----------|--------------|
| Inbound (senders → router)   | `Authorization: Bearer <INBOUND_TOKEN>`, checked by the `bearertokenauth` extension | **Fails closed** — the router refuses to start if `INBOUND_TOKEN` is unset, and rejects any request without the exact token. |
| Outbound (router → SIEM)      | `X-goog-api-key` + `X-Webhook-Access-Key` headers | **Fails closed at startup** — the entrypoint refuses to start if either is unset. |
| Outbound (router → app backend) | `Authorization` header (`APP_AUTH`) | **Fails closed at startup** — the entrypoint refuses to start if unset. |

The startup guard lives in [`entrypoint.sh`](../entrypoint.sh): it verifies
every required endpoint and credential is non-empty before launching the
collector. This exists because the collector on its own would boot with an
empty header and forward telemetry to a destination unauthenticated. With the
guard, a misconfigured deploy stops loudly instead of leaking quietly.

## Where secrets live

Every credential is supplied at runtime as an environment variable and
referenced in the config as `${env:...}`. Nothing sensitive is written into
`config/otel-router.yaml` or baked into the image.

- **Local / testing:** a gitignored `.env` file loaded with `--env-file`. See
  [`.env.example`](../.env.example). `.env` is excluded by
  [`.gitignore`](../.gitignore) so it never reaches version control.
- **Production:** source the values from a secret manager (Docker/Kubernetes
  secrets, AWS/GCP Secret Manager, Vault) injected at deploy time. Environment
  variables are readable by anyone who can `docker inspect` the container or
  read `/proc/<pid>/environ`, so treat env injection as the delivery mechanism,
  not the store.

## Transport security

By default the router speaks plain HTTP, so:

- **Never expose it publicly without TLS** — either terminate TLS in front
  (reverse proxy, load balancer, or a platform that provides HTTPS), or
  enable the router's own TLS mode. Otherwise the inbound bearer token and
  all telemetry cross the network in cleartext.
- **Native TLS is available when fronting isn't.** Set `TLS_ENABLED=true`
  with `TLS_CERT_FILE`/`TLS_KEY_FILE` pointing at a mounted PEM pair and both
  OTLP ports serve TLS. This fails closed: if TLS is requested but the cert
  or key is missing/unreadable, the router refuses to start rather than
  silently falling back to plaintext. The health port (13133) remains plain
  HTTP for liveness probes.
- **Destination endpoints must be `https://`.** An `http://` `APP_ENDPOINT` or
  `SIEM_ENDPOINT` would leak that destination's credential in the request.

## Known limitation: one shared static token

Inbound auth is a **single shared bearer token**. Every sender presents the
same string. This is deliberate and adequate for one organisation running one
fleet of senders, but be aware of the trade-offs:

- **No per-sender identity.** You cannot tell which sender sent what from the
  token alone, and you cannot revoke one sender without rotating everyone.
- **No overlap window.** Rotating the token means a brief period where senders
  still on the old value are rejected until updated. Rotate in a quiet window;
  see USER_GUIDE chapter 12.

### When you outgrow it

If you need per-sender identity, revocation, or zero-downtime rotation, the
upgrade paths (in rough order of effort) are:

1. **Multiple bearer tokens** — front the router with a lightweight auth proxy
   (or an `oidc`/custom auth extension) that accepts a set of tokens and maps
   each to a tenant, so one can be revoked without touching the others.
2. **mTLS** — require client certificates at the TLS-terminating layer. Each
   sender gets its own certificate; revocation is per-certificate. This gives
   strong per-sender identity but needs certificate distribution and rotation
   machinery.
3. **A gateway with real identity** — put an API gateway or service mesh in
   front that issues and validates short-lived, per-sender credentials.

None of these change the router itself; they change what sits in front of it.

## Supply chain

Base and demo images are pinned by digest (`@sha256:...`) in the
[`Dockerfile`](../Dockerfile) and [`docker-compose.yml`](../docker-compose.yml),
so a build always resolves to the exact bytes reviewed. When you upgrade the
Collector, refresh the digest deliberately, read the release notes, and re-run
`./demo/test.sh` before deploying. The container runs as a non-root user
(UID 10001).

## Rotation

See [USER_GUIDE.md](USER_GUIDE.md) chapter 12. In short: generate a new value,
update the secret store and every sender, restart the router. Rotate on a
schedule and immediately if a value may have leaked. A rotated SecOps feed
secret invalidates the old one at once — update the router in the same change.
