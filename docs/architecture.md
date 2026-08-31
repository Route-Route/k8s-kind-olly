# Architecture

## The core split

Prometheus runs **inside** the cluster. Grafana runs **outside**, on the host.
That split isn't arbitrary — it follows from what each component needs.

**Prometheus is a puller.** It reaches out to scrape targets: the kubelet's
`/metrics` and `/metrics/cadvisor` endpoints on every node, kube-state-metrics,
node-exporter, and anything with a ServiceMonitor. Those endpoints live on the
cluster's internal network and are addressed by cluster DNS names and pod IPs.
For Prometheus to scrape them from outside kind, you'd have to expose every one
of them individually through NodePorts or an Ingress, then maintain static
scrape configs pointing at those. Service discovery would break as pods churn.
Running Prometheus in-cluster gives it native Kubernetes SD for free.

**Grafana is a client.** It makes HTTP queries to one endpoint — the Prometheus
API. There's no discovery, no scraping. One reachable URL is the entire
requirement, so it doesn't care where it runs.

The consequence: forward one port out, and you're done.

## Data flow

```
kubelet / cAdvisor  ─┐
kube-state-metrics  ─┼─► Prometheus ─► NodePort 30090 ─► host:9090 ─► Grafana ─► browser
node-exporter       ─┘   (in-cluster)   (node container)  (kind fwd)   (:3000)
```

Every hop is somewhere `scripts/verify.sh` checks, in that order.

## Why NodePort instead of port-forward

`kubectl port-forward` is the tutorial default, and it works, but it has three
properties that make it a poor fit for a repo other people clone:

1. It occupies a terminal, or needs backgrounding and manual cleanup.
2. It dies when the target pod restarts — which happens on every Helm upgrade.
3. It isn't declared anywhere. Someone reading the repo can't tell it's needed.

The NodePort + `extraPortMappings` approach is declarative. The mapping lives
in `kind/cluster.yaml`, comes up with the cluster, survives pod restarts, and
requires no running process.

The cost is coupling: the `nodePort` in the Helm values must match the
`containerPort` in the kind config, and adding a new forwarded port means
recreating the cluster. For a dev environment that's a fine trade.
`scripts/port-forward.sh` is kept around for cases where it isn't.

## Why Grafana reaches `host.docker.internal`

Grafana in a container can't use `localhost` for a host port — `localhost`
inside a container is the container itself. Docker provides
`host.docker.internal` as a special hostname resolving to the host. On Docker
Desktop it works out of the box; on Linux it requires the `extra_hosts:
["host.docker.internal:host-gateway"]` entry in the compose file, which is
there.

An alternative is attaching Grafana directly to kind's Docker network and
addressing the node container by name — `http://monitoring-control-plane:30090`.
That skips the host round-trip entirely and lets you bind kind's ports to
`127.0.0.1` for a tighter security posture. It's documented in
[troubleshooting.md](troubleshooting.md), but it's not the default because it
couples Grafana's config to the cluster's container naming.

## Why control-plane metrics are off

kind runs control-plane components as static pods inside the node container,
with metrics bound to `127.0.0.1` — reachable only from that container's own
loopback interface, not from a Prometheus pod. Their ServiceMonitors therefore
sit permanently DOWN.

Rather than ship a setup with four red targets and a page of firing
`TargetDown` alerts, the values file disables them and the matching alert rules.
The fix — patching bind addresses via `kubeadmConfigPatches` — is real but
version-sensitive (kubeadm changed `extraArgs` syntax between v1beta3 and
v1beta4), so it's opt-in rather than default. Details in
[troubleshooting.md](troubleshooting.md).

For local development this loses very little. The metrics that matter for
"what are my pods doing" come from kubelet, cAdvisor, and kube-state-metrics,
all of which work fine.

## Resource footprint

Tuned for a laptop, roughly:

| Component | Memory request | Memory limit |
|---|---|---|
| Prometheus | 512Mi | 2Gi |
| Alertmanager | 64Mi | 256Mi |
| Operator | 128Mi | 512Mi |
| node-exporter (×3) | 32Mi each | 128Mi each |
| kube-state-metrics | chart default | chart default |

Plus ~1.5GB for the kind nodes themselves. Expect around 3GB resident for the
whole thing under light load. Prometheus retention is capped at 7 days / 4GB
against a 5Gi PVC on kind's built-in `local-path` StorageClass.

If your machine is tight, drop to a single-node cluster by deleting the two
`worker` entries from `kind/cluster.yaml`.
