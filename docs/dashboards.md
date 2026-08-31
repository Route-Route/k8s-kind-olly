# Dashboards

## What ships by default

`scripts/fetch-dashboards.sh` pulls six dashboards into `grafana/dashboards/`.

| File | grafana.com ID | Covers |
|---|---|---|
| `k8s-views-global.json` | 15757 | Cluster-wide CPU, memory, network overview |
| `k8s-views-namespaces.json` | 15759 | Per-namespace resource usage |
| `k8s-views-nodes.json` | 15760 | Per-node capacity and pressure |
| `k8s-views-pods.json` | 15761 | Per-pod containers, restarts, throttling |
| `k8s-system-api-server.json` | 15758 | API server latency and request rates |
| `node-exporter-full.json` | 1860 | Deep host metrics — disk, network, filesystem |

They all assume `kube-prometheus-stack` metric naming, which is what this repo
installs, so they work without relabeling.

## The provisioning gotcha

This is the thing that trips people up, and the reason `fetch-dashboards.sh`
exists instead of a plain `curl`.

Dashboards exported from grafana.com contain an `__inputs` block:

```json
"__inputs": [
  {
    "name": "DS_PROMETHEUS",
    "label": "Prometheus",
    "type": "datasource",
    "pluginId": "prometheus"
  }
]
```

and every panel refers to its datasource as the placeholder `${DS_PROMETHEUS}`.

When you import through the Grafana UI, the wizard shows a dropdown, you pick
your datasource, and Grafana substitutes the real UID before saving. **File
provisioning never runs that wizard.** The placeholder is loaded verbatim, and
every panel renders:

> Datasource ${DS_PROMETHEUS} was not found

The fix is to do the substitution yourself before the file reaches Grafana.
The script:

1. Replaces `${DS_PROMETHEUS}` with the literal UID `prometheus`.
2. Deletes `__inputs`, `__requires`, and `__elements`.
3. Normalises datasource references to the modern `{"type": "prometheus",
   "uid": "prometheus"}` object form, since dashboards of different vintages
   use either a bare string or an object.
4. Nulls out the top-level `id` so Grafana assigns its own.

That UID `prometheus` is declared in
`grafana/provisioning/datasources/prometheus.yaml`. **If you change it there,
change `DS_UID` in the script too** or you'll reintroduce the exact bug.

## Adding a dashboard from grafana.com

Add a line to the `DASHBOARDS` array in `scripts/fetch-dashboards.sh`:

```bash
DASHBOARDS=(
  # ...existing entries...
  "13332:latest:kube-state-metrics-v2.json"   # id:revision:filename
)
```

Then:

```bash
make dashboards
```

Grafana rescans the folder every 30 seconds — no restart needed.

### Pinning revisions

Entries ship with `latest`, so the repo works with no maintenance. The
trade-off is that an upstream update can change your dashboards under you. To
lock a dashboard down, replace `latest` with a revision number from the
"Revisions" tab on its grafana.com page:

```bash
"1860:37:node-exporter-full.json"
```

If a pinned revision ever disappears, the script warns and falls back to
`latest` rather than failing the run.

## Adding a dashboard you built yourself

1. Build it in the Grafana UI.
2. Dashboard settings → JSON Model → copy.
3. Save it as `grafana/dashboards/my-dashboard.json`.
4. Make sure datasource references use `"uid": "prometheus"`, not a random UID
   Grafana generated locally. Search the JSON for `"datasource"` and check.
5. Commit it.

Since your own dashboards aren't gitignored the way fetched ones are, you'll
need to un-ignore them or use a name that doesn't match the pattern. Simplest
fix: delete the `grafana/dashboards/*.json` line from `.gitignore` and commit
everything, which also makes the repo work offline.

## Editing provisioned dashboards

`allowUiUpdates: true` is set in the provider config, so you can edit in the
browser and save. Those edits live in Grafana's database, not in your files.
If the file on disk changes, the file wins and your UI edits vanish.

Workflow that avoids losing work: edit in the UI, export the JSON model, write
it back over the file, commit.

## Useful queries for building your own panels

```promql
# Pod CPU cores, by pod
sum(rate(container_cpu_usage_seconds_total{container!="",pod!=""}[5m])) by (pod)

# Pod memory working set, bytes
sum(container_memory_working_set_bytes{container!="",pod!=""}) by (pod)

# Pods not in Running phase
sum(kube_pod_status_phase{phase!="Running"}) by (namespace, phase)

# Container restarts in the last hour
increase(kube_pod_container_status_restarts_total[1h]) > 0

# Node memory used, percent
100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)

# CPU throttling ratio per container
rate(container_cpu_cfs_throttled_periods_total[5m])
  / rate(container_cpu_cfs_periods_total[5m])

# Scrape targets currently down
up == 0
```

Test them at http://localhost:9090 first — the Prometheus expression browser
gives faster feedback than a Grafana panel editor.
