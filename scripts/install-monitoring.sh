#!/usr/bin/env bash
# Install (or upgrade) kube-prometheus-stack inside the kind cluster.
# Grafana is disabled in the values file — it runs on the host instead.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need helm
need kubectl
require_cluster

info "Adding the prometheus-community Helm repo"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
ok "Helm repo ready"

info "Installing release '$RELEASE_NAME' into namespace '$NAMESPACE'"
dim  "     First run pulls several hundred MB of images — 3-6 minutes is normal."
helm upgrade --install "$RELEASE_NAME" prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --values "$REPO_ROOT/helm/values-kube-prometheus-stack.yaml" \
  --wait \
  --timeout 15m
ok "Helm release deployed"

info "Waiting for Prometheus to report Ready"
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=prometheus \
  -n "$NAMESPACE" --timeout=300s >/dev/null
ok "Prometheus is running"

echo
kubectl get pods -n "$NAMESPACE"
echo
dim "Next: make dashboards && make grafana"
