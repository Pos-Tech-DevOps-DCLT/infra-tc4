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

echo "==> Estado antes do restart:"
kubectl -n "$NAMESPACE" get pods -l app="$DEPLOYMENT"

echo "==> Disparando kubectl rollout restart..."
kubectl -n "$NAMESPACE" rollout restart "deployment/$DEPLOYMENT"

echo "==> Aguardando rollout concluir (timeout 120s)..."
kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout=120s

echo "==> Estado depois do restart:"
kubectl -n "$NAMESPACE" get pods -l app="$DEPLOYMENT"

echo "✅ Self-healing concluído."
