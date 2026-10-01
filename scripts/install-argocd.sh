#!/usr/bin/env bash
# Installs ArgoCD into the EKS cluster and exposes it via a LoadBalancer Service.
# Run this AFTER terraform apply has finished and kubectl is configured.
#
# Usage:
#   ./scripts/install-argocd.sh

set -euo pipefail

echo "==> Current cluster:"
kubectl config current-context
echo ""

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update argo >/dev/null

echo "==> Installing ArgoCD..."
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version "10.9.6" \
  --set server.service.type=LoadBalancer \
  --set configs.params."server\.insecure"=true \
  --set controller.resources.requests.cpu=100m \
  --set controller.resources.requests.memory=256Mi \
  --set controller.resources.limits.cpu=500m \
  --set controller.resources.limits.memory=512Mi \
  --set server.resources.requests.cpu=50m \
  --set server.resources.requests.memory=64Mi \
  --set server.resources.limits.cpu=200m \
  --set server.resources.limits.memory=128Mi \
  --set repoServer.resources.requests.cpu=50m \
  --set repoServer.resources.requests.memory=128Mi \
  --set repoServer.resources.limits.cpu=300m \
  --set repoServer.resources.limits.memory=256Mi \
  --wait --timeout 5m

echo ""
echo "==> Waiting for the LoadBalancer hostname (can take 2-3 min)..."
for i in $(seq 1 30); do
  HOSTNAME=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -n "$HOSTNAME" ]]; then
    break
  fi
  sleep 10
done

ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

echo ""
echo "==================================================================="
echo "ArgoCD URL:      http://${HOSTNAME:-<pending - run: kubectl get svc argocd-server -n argocd>}"
echo "ArgoCD user:     admin"
echo "ArgoCD password: ${ADMIN_PASSWORD}"
echo "==================================================================="
