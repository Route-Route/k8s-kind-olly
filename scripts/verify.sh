#!/usr/bin/env bash
# Walk the whole chain and report which link is broken.
#
#   kind cluster -> pods -> NodePort -> host:9090 -> Grafana -> datasource

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set +e   # keep going so we report every failure, not just the first

fails=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    ok "$label"
  else
    printf '%sfail%s %s\n' "$C_RED" "$C_RESET" "$label"
    fails=$((fails + 1))
  fi
}

info "1. Cluster"
check "kind cluster '$CLUSTER_NAME' exists" \
  bash -c "kind get clusters 2>/dev/null | grep -qx '$CLUSTER_NAME'"
check "kubectl can reach the API server" kubectl cluster-info

info "2. Monitoring workloads"
check "namespace '$NAMESPACE' exists" kubectl get ns "$NAMESPACE"
check "Prometheus pod is Ready" \
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus -n "$NAMESPACE" --timeout=10s
check "kube-state-metrics is Ready" \
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=kube-state-metrics -n "$NAMESPACE" --timeout=10s
check "node-exporter is Ready" \
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus-node-exporter -n "$NAMESPACE" --timeout=10s

info "3. Prometheus reachable from the host"
check "http://localhost:$PROM_HOST_PORT/-/ready responds" \
  curl -fsS --max-time 5 "http://localhost:$PROM_HOST_PORT/-/ready"

# Run an instant query and echo the scalar result, or nothing if empty.
# Uses jq when available; falls back to grep for the last quoted number in the
# value tuple, e.g.  "value":[1756614000.123,"27"]  ->  27
promq() {
  local out
  out=$(curl -fsSG --max-time 10 \
        --data-urlencode "query=$1" \
        "http://localhost:$PROM_HOST_PORT/api/v1/query" 2>/dev/null) || return 1
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$out" | jq -r '.data.result[0].value[1] // empty' 2>/dev/null
  else
    printf '%s' "$out" | grep -o '"value":\[[^]]*\]' \
      | grep -oE '"[0-9.]+"\]?$' | tr -d '"]'
  fi
}

if curl -fsS --max-time 5 "http://localhost:$PROM_HOST_PORT/-/ready" >/dev/null 2>&1; then
  up=$(promq 'count(up == 1)')
  if [[ -n "${up:-}" && "${up%%.*}" -gt 0 ]]; then
    ok "Prometheus is scraping ${up%%.*} healthy targets"
  else
    warn "Prometheus is up but reports no healthy targets yet — give it 60s"
  fi

  pods=$(promq 'count(kube_pod_info)')
  if [[ -n "${pods:-}" && "${pods%%.*}" -gt 0 ]]; then
    ok "kube-state-metrics data present (${pods%%.*} pods visible)"
  else
    printf '%sfail%s kube_pod_info returns nothing — dashboards will be empty\n' "$C_RED" "$C_RESET"
    fails=$((fails + 1))
  fi

  cadv=$(promq 'count(container_memory_working_set_bytes)')
  if [[ -n "${cadv:-}" && "${cadv%%.*}" -gt 0 ]]; then
    ok "cAdvisor container metrics present"
  else
    warn "No cAdvisor metrics yet — CPU/memory panels will be empty"
  fi
fi

info "4. Grafana"
if curl -fsS --max-time 5 "http://localhost:$GRAFANA_PORT/api/health" >/dev/null 2>&1; then
  ok "Grafana is healthy on :$GRAFANA_PORT"
  if curl -fsS --max-time 10 -u admin:admin \
      "http://localhost:$GRAFANA_PORT/api/datasources/uid/prometheus" >/dev/null 2>&1; then
    ok "Prometheus datasource is provisioned"
  else
    warn "Datasource 'prometheus' not found — check grafana/provisioning/datasources/"
  fi
  count=$(ls -1 "$REPO_ROOT/grafana/dashboards"/*.json 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$count" -gt 0 ]]; then
    ok "$count dashboard file(s) on disk"
  else
    warn "No dashboard JSON files — run: make dashboards"
  fi
else
  warn "Grafana not responding on :$GRAFANA_PORT — run: make grafana"
fi

echo
if [[ $fails -eq 0 ]]; then
  printf '%sAll checks passed.%s Open http://localhost:%s\n' "$C_GREEN" "$C_RESET" "$GRAFANA_PORT"
else
  printf '%s%d check(s) failed.%s See docs/troubleshooting.md\n' "$C_RED" "$fails" "$C_RESET"
  exit 1
fi
