#!/usr/bin/env bash
# Download Kubernetes dashboards from grafana.com and make them
# provisioning-safe.
#
# Why this script exists instead of just committing the JSON:
#
# Dashboards exported from grafana.com carry an `__inputs` block and reference
# their datasource as the placeholder "${DS_PROMETHEUS}". That placeholder is
# filled in by the interactive Import wizard. File-based provisioning never runs
# that wizard, so the placeholder survives into the loaded dashboard and every
# panel renders "Datasource ${DS_PROMETHEUS} was not found".
#
# So we rewrite the placeholder to the concrete datasource uid declared in
# grafana/provisioning/datasources/prometheus.yaml, and strip the input blocks.
#
# Run once after cloning. Commit the results if you want an offline-capable repo.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need curl

DASHBOARD_DIR="$REPO_ROOT/grafana/dashboards"
DS_UID="prometheus"   # must match `uid:` in provisioning/datasources/prometheus.yaml
GRAFANA_COM="https://grafana.com/api/dashboards"

# Format:  "grafana.com-id : revision : output-filename"
#
# Revision is "latest" by default so this works without maintenance. For a
# reproducible build, replace it with a specific number from the "Revisions"
# tab on the dashboard's grafana.com page — e.g. "1860:37:node-exporter.json".
# If a pinned revision 404s, the script falls back to latest.
DASHBOARDS=(
  "15757:latest:k8s-views-global.json"
  "15759:latest:k8s-views-namespaces.json"
  "15760:latest:k8s-views-nodes.json"
  "15761:latest:k8s-views-pods.json"
  "15758:latest:k8s-system-api-server.json"
  "1860:latest:node-exporter-full.json"
)

mkdir -p "$DASHBOARD_DIR"

have_jq=false
command -v jq >/dev/null 2>&1 && have_jq=true
$have_jq || warn "jq not found — using sed-only cleanup. Works, but less thorough. (sudo apt install jq)"

download() {  # id, rev, outfile -> 0 on success
  curl -fsSL --retry 3 --max-time 60 \
    "$GRAFANA_COM/$1/revisions/$2/download" -o "$3"
}

failed=0
for entry in "${DASHBOARDS[@]}"; do
  id="${entry%%:*}"
  rest="${entry#*:}"
  rev="${rest%%:*}"
  file="${rest#*:}"
  dest="$DASHBOARD_DIR/$file"
  tmp="$(mktemp)"

  info "Fetching dashboard $id (rev $rev) -> $file"

  if ! download "$id" "$rev" "$tmp"; then
    if [[ "$rev" != "latest" ]] && download "$id" "latest" "$tmp"; then
      warn "Revision $rev unavailable for $id; used latest instead."
    else
      warn "Could not download dashboard $id — skipping."
      rm -f "$tmp"; failed=$((failed + 1)); continue
    fi
  fi

  # Sanity check: grafana.com returns HTML on some error paths.
  if ! head -c 1 "$tmp" | grep -q '{'; then
    warn "Dashboard $id did not return JSON — skipping."
    rm -f "$tmp"; failed=$((failed + 1)); continue
  fi

  # 1. Replace the import placeholder with our real datasource uid.
  sed -i \
    -e "s/\${DS_PROMETHEUS}/$DS_UID/g" \
    -e "s/\"\${datasource}\"/\"$DS_UID\"/g" \
    "$tmp"

  if $have_jq; then
    # 2. Strip import-wizard metadata and normalise datasource references to
    #    the modern {type, uid} object form. Panels pointing at a template
    #    variable like "$datasource" are deliberately left alone — Grafana
    #    resolves those against the default datasource.
    out="$(mktemp)"
    if jq --arg uid "$DS_UID" '
          del(.__inputs, .__requires, .__elements)
          | .id = null
          | walk(
              if type == "object" and has("datasource") then
                if (.datasource | type) == "object"
                   and (.datasource.type // "") == "prometheus"
                  then .datasource.uid = $uid
                elif (.datasource | type) == "string"
                     and (.datasource | test("prometheus"; "i"))
                  then .datasource = {type: "prometheus", uid: $uid}
                else . end
              else . end
            )
        ' "$tmp" > "$out" 2>/dev/null && [[ -s "$out" ]]; then
      mv "$out" "$dest"
    else
      warn "jq pass failed for $file — writing the sed-only version."
      rm -f "$out"; cp "$tmp" "$dest"
    fi
  else
    cp "$tmp" "$dest"
  fi

  rm -f "$tmp"
  ok "$file"
done

echo
info "Dashboards in $DASHBOARD_DIR:"
ls -1 "$DASHBOARD_DIR" 2>/dev/null | grep '\.json$' || warn "none — check your network connection"

echo
if [[ $failed -gt 0 ]]; then
  warn "$failed dashboard(s) could not be fetched. You can still import them by"
  dim  "     ID through the Grafana UI — see README.md."
fi
dim "Grafana rescans this folder every 30s. No restart needed if it's already running."
