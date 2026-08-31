#!/usr/bin/env bash
# Start Grafana on the host via Docker Compose, with the datasource and
# dashboards already provisioned from this repo.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need docker

COMPOSE_FILE="$REPO_ROOT/grafana/docker-compose.yml"

# Support both `docker compose` (v2 plugin) and legacy `docker-compose`.
if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  die "Neither 'docker compose' nor 'docker-compose' is available."
fi

if ! ls "$REPO_ROOT/grafana/dashboards"/*.json >/dev/null 2>&1; then
  warn "No dashboard JSON files found. Run: make dashboards"
fi

info "Starting Grafana"
"${COMPOSE[@]}" -f "$COMPOSE_FILE" up -d
ok "Container started"

info "Waiting for Grafana to answer on :$GRAFANA_PORT"
for i in $(seq 1 60); do
  if curl -fsS "http://localhost:$GRAFANA_PORT/api/health" >/dev/null 2>&1; then
    ok "Grafana is healthy"
    break
  fi
  [[ $i -eq 60 ]] && die "Grafana did not become healthy. Logs: docker logs grafana-local"
  sleep 2
done

echo
printf '  Grafana   %s\n' "http://localhost:$GRAFANA_PORT"
printf '  Login     admin / admin\n'
printf '  Dashboards live in the "Kubernetes" folder\n'
echo
dim "Verify the whole chain with: make verify"
