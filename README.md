# kind + Prometheus + local Grafana

A reproducible local Kubernetes monitoring stack: a **kind** cluster running
Prometheus, scraped into a **Grafana instance running on the host machine**.

Everything is version-controlled — the cluster shape, the Helm values, the
Grafana datasource, and the dashboards. Clone it on another laptop, run one
command, get the identical setup.

```
┌─ Local Machine ──────────────────────────────────────────────┐
│                                                             │
│   Grafana (Docker, :3000)                                   │
│        │                                                    │
│        │ http://host.docker.internal:9090                   │
│        ▼                                                    │
│   localhost:9090 ──┐                                        │
│                    │  kind extraPortMapping                 │
│   ┌────────────────▼──────────────────────────────────┐     │
│   │ kind cluster "monitoring"                         │     │
│   │                                                   │     │
│   │   NodePort 30090 → Prometheus                     │     │
│   │                       ▲                           │     │
│   │              ┌────────┼────────┐                  │     │
│   │        kubelet   kube-state   node-exporter       │     │
│   │        cAdvisor    metrics                        │     │
│   └───────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

**Why Prometheus lives inside the cluster:** it needs to scrape the kubelet,
cAdvisor, and kube-state-metrics, which only exist on the cluster network.
Running it inside and forwarding one port out is far simpler than exposing
every scrape target. Grafana has no such constraint — it only ever talks to
Prometheus, so it stays on the host.

---

## Quick start

```bash
git clone https://github.com/Route-Route/k8s-kind-olly.git kind-k8s-monitoring
cd kind-k8s-monitoring

make up
```

That runs the whole chain: create cluster → install Prometheus → fetch
dashboards → start Grafana → verify. Budget 5–10 minutes on first run,
mostly image pulls.

Then open **http://localhost:3000** (`admin` / `admin`) and look in the
**Kubernetes** folder.

---

## Prerequisites

| Tool | Minimum | Install on Ubuntu |
|---|---|---|
| Docker | 20.10 | `curl -fsSL https://get.docker.com \| sh` then `sudo usermod -aG docker $USER` |
| kind | 0.20 | `go install sigs.k8s.io/kind@latest` or [download a release binary](https://github.com/kubernetes-sigs/kind/releases) |
| kubectl | 1.28 | `sudo snap install kubectl --classic` |
| Helm | 3.12 | `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` |
| curl, jq | any | `sudo apt install -y curl jq` |

`jq` is optional but strongly recommended — `fetch-dashboards.sh` uses it to
clean dashboard JSON properly.

Check everything at once:

```bash
docker --version && kind --version && kubectl version --client && helm version --short
```

Log out and back in after adding the current user to the `docker` group, or `docker
info` will fail with a permissions error.

---

## Step by step

Prefer running the pieces ?? Each `make` target maps to one script.

### 1. Create the cluster

```bash
make cluster          # scripts/create-cluster.sh
```

Builds a 3-node cluster (1 control-plane, 2 workers) from
[`kind/cluster.yaml`](kind/cluster.yaml). The important part of that file is
`extraPortMappings`, which wires host port 9090 straight through to NodePort
30090 inside the cluster. That's what removes the need for a permanently
running `kubectl port-forward`.

Verify:

```bash
kubectl get nodes
```

### 2. Install Prometheus

```bash
make monitoring       # scripts/install-monitoring.sh
```

Installs `kube-prometheus-stack` using
[`helm/values-kube-prometheus-stack.yaml`](helm/values-kube-prometheus-stack.yaml).
Three things in those values are worth knowing about:

- **`grafana.enabled: false`** — the chart ships its own Grafana. We already
  have one on the host, so the bundled copy is disabled to avoid running two.
- **`serviceMonitorSelectorNilUsesHelmValues: false`** — without this,
  Prometheus only picks up ServiceMonitors labelled with the Helm release name,
  and any monitor we write ourrself is silently ignored.
- **Control-plane scrapes disabled** — on kind, kube-scheduler,
  kube-controller-manager, etcd and kube-proxy bind metrics to `127.0.0.1`
  inside the node container, so those targets can never be scraped and just sit
  red forever. See [docs/troubleshooting.md](docs/troubleshooting.md) to turn
  them on properly.

Watch it come up:

```bash
make pods
```

`PodInitializing` and `ContainerCreating` for a few minutes is normal — the
Prometheus and Alertmanager images are large.

Prometheus is now on **http://localhost:9090** directly. Try a query like
`up` or `kube_pod_info` to confirm data is flowing before touching Grafana.

### 3. Fetch dashboards

```bash
make dashboards       # scripts/fetch-dashboards.sh
```

Downloads six community dashboards into `grafana/dashboards/` and rewrites
them so file-based provisioning works. This rewriting is the part people
usually miss — see [docs/dashboards.md](docs/dashboards.md) for why raw
grafana.com JSON renders as "Datasource ${DS_PROMETHEUS} was not found".

### 4. Start Grafana

```bash
make grafana          # scripts/start-grafana.sh
```

Brings up Grafana in Docker with `grafana/provisioning/` mounted in. The
datasource and dashboard folder are configured on startup, so there is nothing
to click through.

Already running Grafana some other way? See
[Using existing Grafana](#using-existing-grafana) below.

### 5. Verify

```bash
make verify           # scripts/verify.sh
```

Walks each hop — cluster, pods, NodePort, host port, Grafana, datasource — and
tells which one is broken rather than making guess.

---

## Using existing Grafana

The compose file is a convenience, not a requirement. To point a Grafana
already run at this cluster:

**Native binary / systemd service (`apt install grafana`)**

```bash
sudo cp grafana/provisioning/datasources/prometheus.yaml \
        /etc/grafana/provisioning/datasources/
sudo cp grafana/provisioning/dashboards/provider.yaml \
        /etc/grafana/provisioning/dashboards/
sudo mkdir -p /var/lib/grafana/dashboards
sudo cp grafana/dashboards/*.json /var/lib/grafana/dashboards/
```

Then edit the copied datasource file and change the URL from
`http://host.docker.internal:9090` to **`http://localhost:9090`** — a native
process reaches the forwarded port directly. Restart:

```bash
sudo systemctl restart grafana-server
```

**Configuring by hand in the UI instead**

1. Connections → Data sources → Add new data source → Prometheus
2. URL: `http://localhost:9090` (native) or `http://host.docker.internal:9090`
   (Docker)
3. Save & test
4. Dashboards → New → Import → paste one of these IDs → select Prometheus
   datasource:

   | ID | Dashboard |
   |---|---|
   | 15757 | Kubernetes / Views / Global |
   | 15759 | Kubernetes / Views / Namespaces |
   | 15760 | Kubernetes / Views / Nodes |
   | 15761 | Kubernetes / Views / Pods |
   | 15758 | Kubernetes / System / API Server |
   | 1860 | Node Exporter Full |

Importing through the wizard handles the datasource placeholder, which
is why manual import works even though raw file provisioning needs the fixup.

---

## Everyday commands

```bash
make help              # list every target
make pods              # what's running in the monitoring namespace
make targets           # Prometheus scrape target health, grouped by job
make logs              # tail Grafana logs
make restart-grafana   # reload after editing provisioning files
make down              # delete the cluster and the Grafana container
```

## Configuration

Override defaults with environment variables:

```bash
CLUSTER_NAME=devcluster make cluster
PROM_HOST_PORT=19090 make verify
```

| Variable | Default | Meaning |
|---|---|---|
| `CLUSTER_NAME` | `monitoring` | kind cluster name |
| `NAMESPACE` | `monitoring` | namespace for the stack |
| `RELEASE_NAME` | `kube-prometheus-stack` | Helm release name |
| `PROM_HOST_PORT` | `9090` | host port for Prometheus |
| `GRAFANA_PORT` | `3000` | host port for Grafana |

Changing `PROM_HOST_PORT` also means editing `hostPort` in `kind/cluster.yaml`
and the `url` in the datasource file — they have to agree.

## Repository layout

```
.
├── Makefile                              one-command workflows
├── kind/cluster.yaml                     cluster shape + port mappings
├── helm/
│   └── values-kube-prometheus-stack.yaml Prometheus tuning for kind
├── grafana/
│   ├── docker-compose.yml                host Grafana
│   ├── provisioning/
│   │   ├── datasources/prometheus.yaml   auto-wired datasource
│   │   └── dashboards/provider.yaml      auto-load dashboards from disk
│   └── dashboards/                       dashboard JSON (fetched)
├── scripts/                              one script per step
└── docs/
    ├── architecture.md                   how the pieces connect, and why
    ├── dashboards.md                     adding and customising dashboards
    └── troubleshooting.md                when something is red
```

## Notes and caveats

- **Data is not durable across cluster rebuilds.** `make down` deletes the
  cluster and its PVC. Metrics history goes with it. That's fine for local dev;
  don't build anything care about on it.
- **Prometheus binds to `0.0.0.0:9090` by default**, so others on network
  can reach it. On untrusted networks, see the `listenAddress` comment in
  `kind/cluster.yaml`.
- **Credentials are `admin`/`admin`.** Local only. Change them before exposing
  Grafana anywhere.

## Troubleshooting

Start with `make verify`, then see
[docs/troubleshooting.md](docs/troubleshooting.md). The usual suspects:
Docker not running, images still pulling, `host.docker.internal` unresolvable
on older Docker, or a port 9090 conflict with something else on machine.
