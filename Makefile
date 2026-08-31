SHELL := /usr/bin/env bash

CLUSTER_NAME ?= monitoring
NAMESPACE    ?= monitoring
export CLUSTER_NAME NAMESPACE

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@echo ""
	@echo "  kind + Prometheus + local Grafana"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo ""

.PHONY: up
up: cluster monitoring dashboards grafana verify ## Full setup, start to finish

.PHONY: cluster
cluster: ## Create the kind cluster
	@bash scripts/create-cluster.sh

.PHONY: monitoring
monitoring: ## Install kube-prometheus-stack into the cluster
	@bash scripts/install-monitoring.sh

.PHONY: dashboards
dashboards: ## Download and patch Grafana dashboard JSON
	@bash scripts/fetch-dashboards.sh

.PHONY: grafana
grafana: ## Start Grafana on the host (Docker)
	@bash scripts/start-grafana.sh

.PHONY: verify
verify: ## Check every link in the chain
	@bash scripts/verify.sh

.PHONY: port-forward
port-forward: ## Fallback: kubectl port-forward Prometheus to :9090
	@bash scripts/port-forward.sh

.PHONY: logs
logs: ## Tail Grafana container logs
	@docker logs -f grafana-local

.PHONY: pods
pods: ## Show monitoring namespace pods
	@kubectl get pods -n $(NAMESPACE) -o wide

.PHONY: targets
targets: ## List Prometheus scrape targets and their health
	@curl -fsS http://localhost:9090/api/v1/targets \
		| { command -v jq >/dev/null && jq -r '.data.activeTargets[] | "\(.health)\t\(.labels.job)"' | sort | uniq -c || cat; }

.PHONY: restart-grafana
restart-grafana: ## Recreate the Grafana container (picks up provisioning changes)
	@docker compose -f grafana/docker-compose.yml up -d --force-recreate

.PHONY: down
down: ## Tear down Grafana and the kind cluster
	@bash scripts/teardown.sh
