#!/usr/bin/env bash
# Liga o APM (New Relic) no cluster de uma vez, depois que os nos/RDS foram
# retomados (docs/PAUSE-RESUME.md): Secret -> manifesto -> restart do
# collector -> trafego real no evaluation-service -> checagem do export.
#
# Uso (da raiz do repo, com o kubectl apontando para o EKS):
#   ./scripts/apm-enable.sh                 # pede a key (nao ecoa no terminal)
#   NEW_RELIC_LICENSE_KEY=... ./scripts/apm-enable.sh
#   DURATION=120 ./scripts/apm-enable.sh    # segundos de trafego (default 60)
set -euo pipefail

NS=monitoring
DURATION="${DURATION:-60}"

echo "==> Contexto: $(kubectl config current-context)"
kubectl get nodes --no-headers | grep -q " Ready" \
  || { echo "ERRO: nenhum no Ready — retome o node group antes (docs/PAUSE-RESUME.md)"; exit 1; }

# 1. Secret (fora do Git). Recria se ja existir, para permitir trocar a key.
if [[ -z "${NEW_RELIC_LICENSE_KEY:-}" ]]; then
  read -rsp "New Relic INGEST - LICENSE key: " NEW_RELIC_LICENSE_KEY; echo
fi
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create secret generic newrelic-license \
  --from-literal=license-key="$NEW_RELIC_LICENSE_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. Manifesto das Applications de observabilidade (aplicado a mao) e sync
kubectl apply -f argocd/applications-observability.yaml
echo "==> Aguardando ArgoCD sincronizar o otel-collector..."
for _ in $(seq 1 30); do
  s=$(kubectl -n argocd get application otel-collector -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
  [[ "$s" == "Synced/Healthy" ]] && break
  sleep 10
done
echo "    otel-collector: ${s:-desconhecido}"

# 3. Restart para o collector ler o env do Secret
kubectl -n "$NS" rollout restart ds/otel-collector-agent
kubectl -n "$NS" rollout status ds/otel-collector-agent --timeout=180s

# 4. Trafego real (o /health e excluido da telemetria)
HOST=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
URL="http://$HOST/evaluate/evaluate?user_id=u1&flag_name=demo"
echo "==> Teste: $URL"
curl -s -m 10 "$URL"; echo
echo "==> Gerando trafego por ${DURATION}s..."
end=$((SECONDS + DURATION))
while (( SECONDS < end )); do
  curl -s -o /dev/null -m 5 "$URL" || true
  sleep 0.5
done

# 5. Checagem do export
sleep 10
LOGS=$(kubectl -n "$NS" logs -l app.kubernetes.io/instance=otel-collector --since=3m --tail=-1 2>/dev/null || true)
if grep -qiE "Exporting failed|Status Code 40[0-9]" <<<"$LOGS"; then
  echo "FALHOU — erro no export para o New Relic:"
  grep -iE "error|failed" <<<"$LOGS" | tail -5
  exit 1
fi
echo
echo "OK — collector exportando sem erros. No New Relic:"
echo "  APM & Services -> Services - OpenTelemetry (5 servicos)"
echo "  evaluation-service -> Service map / Distributed tracing"
echo "  NRQL: FROM Span SELECT count(*) FACET service.name SINCE 30 minutes ago"
