#!/usr/bin/env bash
# Shared helpers. Sourced by the other scripts, not run directly.

set -euo pipefail

# Resolve the repo root regardless of where the script was invoked from.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

CLUSTER_NAME="${CLUSTER_NAME:-monitoring}"
NAMESPACE="${NAMESPACE:-monitoring}"
RELEASE_NAME="${RELEASE_NAME:-kube-prometheus-stack}"
PROM_HOST_PORT="${PROM_HOST_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
export CLUSTER_NAME NAMESPACE RELEASE_NAME PROM_HOST_PORT GRAFANA_PORT

# --- output helpers --------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'
else
  C_RESET=''; C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''
fi

info()  { printf '%s==>%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '%s warn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%sfail%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }
dim()   { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

# --- preflight -------------------------------------------------------------
need() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is not installed or not on PATH. See docs in README.md → Prerequisites."
}

require_cluster() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" \
    || die "kind cluster '$CLUSTER_NAME' does not exist. Run: make cluster"
}
