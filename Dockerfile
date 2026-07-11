# Contrib distribution: needed for the bearertokenauth extension guarding the
# inbound endpoints. Bump the pin deliberately; check release notes first.
FROM otel/opentelemetry-collector-contrib:0.156.0

COPY config/otel-router.yaml /etc/otelcol-contrib/config.yaml

EXPOSE 4317 4318
