#!/usr/bin/env bash
# Tear everything down: Grafana container, then the kind cluster.
# Pass --keep-grafana-data to preserve the Grafana volume.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEEP_DATA=false
[[ "${1:-}" == "--keep-grafana-data" ]] && KEEP_DATA=true

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  COMPOSE=()
fi

if [[ ${#COMPOSE[@]} -gt 0 ]]; then
  info "Stopping Grafana"
  if $KEEP_DATA; then
    "${COMPOSE[@]}" -f "$REPO_ROOT/grafana/docker-compose.yml" down 2>/dev/null || true
    ok "Grafana stopped (volume kept)"
  else
    "${COMPOSE[@]}" -f "$REPO_ROOT/grafana/docker-compose.yml" down -v 2>/dev/null || true
    ok "Grafana stopped and volume removed"
  fi
fi

if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  info "Deleting kind cluster '$CLUSTER_NAME'"
  kind delete cluster --name "$CLUSTER_NAME"
  ok "Cluster deleted"
else
  dim "No kind cluster named '$CLUSTER_NAME' to delete."
fi

echo
ok "Teardown complete."
