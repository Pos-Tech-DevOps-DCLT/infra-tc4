#!/usr/bin/env bash
# Self-healing do auth-service: reinicia o Deployment e espera o rollout
# concluir. Chamado pelo workflow
# .github/workflows/self-healing-auth-service.yml — requer kubectl já
# configurado (aws eks update-kubeconfig) e permissão de "edit" no namespace
# auth-service (ver terraform/modules/alerting).
#
# Uso: ./scripts/self-heal-auth-service.sh
set -euo pipefail

NAMESPACE="auth-service"
DEPLOYMENT="auth-service"
MIN_REPLICAS=1

echo "==> Estado antes do restart:"
kubectl -n "$NAMESPACE" get pods -l app="$DEPLOYMENT"

# "kubectl rollout restart" só recria pods que já deveriam existir — se as
# réplicas desejadas estiverem em 0 (alguém escalou manualmente, uma HPA/KEDA
# zerou por engano, etc.), um restart sozinho é um no-op e o serviço continua
# fora do ar. Garantir replicas>=1 cobre esse caso real além do "pod travado"
# que o restart já resolve.
CURRENT_REPLICAS=$(kubectl -n "$NAMESPACE" get "deployment/$DEPLOYMENT" -o jsonpath='{.spec.replicas}')
if [ "$CURRENT_REPLICAS" -lt "$MIN_REPLICAS" ]; then
  echo "==> Deployment está com $CURRENT_REPLICAS réplicas (esperado >= $MIN_REPLICAS) — escalando..."
  kubectl -n "$NAMESPACE" scale "deployment/$DEPLOYMENT" --replicas="$MIN_REPLICAS"
fi

echo "==> Disparando kubectl rollout restart..."
kubectl -n "$NAMESPACE" rollout restart "deployment/$DEPLOYMENT"

echo "==> Aguardando rollout concluir (timeout 120s)..."
kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout=120s

echo "==> Estado depois do restart:"
kubectl -n "$NAMESPACE" get pods -l app="$DEPLOYMENT"

echo "✅ Self-healing concluído."
