#!/usr/bin/env bash
# Testa a license key do New Relic SEM o cluster: sobe o mesmo OTel Collector
# do cluster (contrib 0.161.0) no Docker, com o mesmo exporter
# otlphttp/newrelic, e manda traces sinteticos com o telemetrygen.
#
# Uso:
#   ./scripts/apm-local-test.sh            # pede a key (nao ecoa no terminal)
#   NEW_RELIC_LICENSE_KEY=... ./scripts/apm-local-test.sh
#   NR_OTLP_ENDPOINT=https://otlp.eu01.nr-data.net ./scripts/apm-local-test.sh  # conta EU
#
# Sucesso: o servico "apm-local-test" aparece no New Relic em ~1 min
#   (NRQL: FROM Span SELECT count(*) WHERE service.name = 'apm-local-test' SINCE 10 minutes ago)
set -euo pipefail

OTEL_VERSION=0.161.0
NR_OTLP_ENDPOINT="${NR_OTLP_ENDPOINT:-https://otlp.nr-data.net}"
NAME=apm-local-test-collector
TMP=$(mktemp -d)
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

if [[ -z "${NEW_RELIC_LICENSE_KEY:-}" ]]; then
  [[ -t 0 ]] || { echo "ERRO: sem terminal interativo para pedir a key. Rode num terminal normal ou exporte NEW_RELIC_LICENSE_KEY."; exit 1; }
  read -rsp "New Relic INGEST - LICENSE key: " NEW_RELIC_LICENSE_KEY; echo
fi
export NEW_RELIC_LICENSE_KEY
[[ "$NEW_RELIC_LICENSE_KEY" == NRAK-* ]] && { echo "ERRO: essa e uma User key (NRAK-...). Use a INGEST - LICENSE."; exit 1; }

cat > "$TMP/config.yaml" <<EOF
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
processors:
  batch:
    timeout: 1s
exporters:
  debug:
    verbosity: basic
  otlphttp/newrelic:
    endpoint: ${NR_OTLP_ENDPOINT}
    compression: gzip
    headers:
      api-key: \${env:NEW_RELIC_LICENSE_KEY}
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug, otlphttp/newrelic]
EOF

echo "==> Subindo collector ${OTEL_VERSION} -> ${NR_OTLP_ENDPOINT}"
docker run -d --name "$NAME" -e NEW_RELIC_LICENSE_KEY \
  -v "$TMP/config.yaml:/etc/otelcol/config.yaml:ro" \
  "otel/opentelemetry-collector-contrib:${OTEL_VERSION}" --config=/etc/otelcol/config.yaml >/dev/null
sleep 3

echo "==> Enviando 10 traces (1 span raiz + 3 filhos cada)"
docker run --rm --network "container:${NAME}" \
  "ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v${OTEL_VERSION}" \
  traces --otlp-endpoint localhost:4317 --otlp-insecure \
  --service apm-local-test --traces 10 --child-spans 3 >/dev/null 2>&1

sleep 8
LOGS=$(docker logs "$NAME" 2>&1)
if grep -qiE "Exporting failed|permanent error|Status Code 40[0-9]|connection refused|no such host" <<<"$LOGS"; then
  echo "FALHOU — erro no export para o New Relic:"
  grep -iE "error|failed" <<<"$LOGS" | tail -5
  echo
  echo "403 = key errada/tipo errado ou regiao errada (US: otlp.nr-data.net / EU: otlp.eu01.nr-data.net)"
  exit 1
fi
grep -E "Traces" <<<"$LOGS" | tail -2
echo
echo "OK — export aceito pelo New Relic. Confira em ~1 min:"
echo "  APM & Services -> Services - OpenTelemetry -> apm-local-test"
echo "  NRQL: FROM Span SELECT count(*) WHERE service.name = 'apm-local-test' SINCE 10 minutes ago"
