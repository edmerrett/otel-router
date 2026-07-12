# Static shell layer: the collector image is distroless (no shell), so we add
# a single busybox binary to validate required secrets at startup and to
# health-check. The uclibc build is statically linked, so it runs in the
# distroless image (the default glibc build would need an interpreter that
# isn't there). Pinned by digest; tag shown for humans: busybox:1.37-uclibc
FROM busybox@sha256:fd8d9aa63ba2f0982b5304e1ee8d3b90a210bc1ffb5314d980eb6962f1a9715d AS busybox

# Contrib distribution: needed for bearertokenauth (inbound guard) and
# health_check. Pinned by digest; tag: otel/opentelemetry-collector-contrib:0.156.0
# Bump deliberately: refresh the digest and read the release notes first.
FROM otel/opentelemetry-collector-contrib@sha256:125bdbeb7590cc1952c5b3430ecf14063568980c2c93d5b38676cc0446ed8108

USER 0
COPY --from=busybox --chmod=0755 /bin/busybox /bin/busybox
COPY --chmod=0755 entrypoint.sh /entrypoint.sh
COPY config/base.yaml /etc/otelcol-contrib/base.yaml
COPY config/destinations.yaml /etc/otelcol-contrib/destinations.yaml
COPY config/tls.yaml /etc/otelcol-contrib/tls.yaml
USER 10001

EXPOSE 4317 4318 13133

# entrypoint.sh fails closed if INBOUND_TOKEN (or anything in REQUIRE_ENV) is
# missing, then execs the collector with the args from CMD. The collector
# deep-merges the two --config files into one effective config: base.yaml
# (receivers + auth) plus destinations.yaml (exporters + pipelines). Mount your
# own destinations.yaml over the baked one to change where telemetry goes.
# Run via busybox sh since the base image ships no shell.
ENTRYPOINT ["/bin/busybox", "sh", "/entrypoint.sh"]
CMD ["--config", "/etc/otelcol-contrib/base.yaml", "--config", "/etc/otelcol-contrib/destinations.yaml"]

# Liveness via the health_check extension (config exposes it on :13133).
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["/bin/busybox", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:13133/"]
