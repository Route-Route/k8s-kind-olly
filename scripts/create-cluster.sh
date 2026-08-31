#!/usr/bin/env bash
# Create the kind cluster defined in kind/cluster.yaml.
# Safe to re-run: skips creation if the cluster already exists.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need docker
need kind
need kubectl

info "Checking Docker daemon"
docker info >/dev/null 2>&1 || die "Docker is not running. Start it and try again."
ok "Docker is up"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  warn "Cluster '$CLUSTER_NAME' already exists — skipping creation."
  dim  "     To rebuild from scratch: make down && make cluster"
else
  info "Creating kind cluster '$CLUSTER_NAME' (this pulls node images the first time)"
  kind create cluster --config "$REPO_ROOT/kind/cluster.yaml" --wait 120s
  ok "Cluster created"
fi

info "Switching kubectl context"
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
ok "Context is kind-$CLUSTER_NAME"

info "Waiting for all nodes to be Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
ok "Nodes ready"

echo
kubectl get nodes -o wide
echo
dim "Next: make monitoring"
