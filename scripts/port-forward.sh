#!/usr/bin/env bash
# FALLBACK ONLY.
#
# The kind config in this repo already forwards host:9090 to the Prometheus
# NodePort, so you normally do NOT need this. Use it if:
#   - you created your cluster without kind/cluster.yaml, or
#   - you removed the extraPortMappings, or
#   - you want to reach Prometheus on a different local port.
#
# Blocks the terminal. Ctrl-C to stop. Dies if the pod restarts.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl
require_cluster

LOCAL_PORT="${1:-$PROM_HOST_PORT}"

if curl -fsS "http://localhost:$LOCAL_PORT/-/ready" >/dev/null 2>&1; then
  warn "Something already serves Prometheus on localhost:$LOCAL_PORT."
  dim  "     Probably kind's NodePort mapping — you likely don't need this script."
  exit 0
fi

info "Forwarding localhost:$LOCAL_PORT -> Prometheus in-cluster :9090"
dim  "     Leave this terminal open. Ctrl-C to stop."
exec kubectl port-forward -n "$NAMESPACE" \
  "svc/${RELEASE_NAME}-prometheus" "${LOCAL_PORT}:9090"
