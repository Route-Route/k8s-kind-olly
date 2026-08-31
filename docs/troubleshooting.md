# Troubleshooting

Run `make verify` first. It walks the chain in order and names the failing hop.

---

## Pods stuck in `ContainerCreating` or `PodInitializing`

Normal for 3–6 minutes on a first install — the Prometheus and Alertmanager
images are hundreds of megabytes and kind pulls them fresh.

Past that, look at the events:

```bash
kubectl describe pod -n monitoring prometheus-kube-prometheus-stack-prometheus-0
```

Read the **Events** block at the bottom.

| Event says | Cause | Fix |
|---|---|---|
| `ErrImagePull` / `ImagePullBackOff` | No network, or rate limited | Check connectivity; if Docker Hub rate-limits you, `docker login` |
| `FailedScheduling ... Insufficient memory` | Host too small | Cut to one node — delete the `worker` entries in `kind/cluster.yaml`, recreate |
| `FailedMount` / pending PVC | StorageClass missing | `kubectl get sc` should list `standard`. If not, recreate the cluster |
| No events, just slow | Still pulling | `docker exec monitoring-control-plane crictl images` to watch progress |

---

## `localhost:9090` refuses the connection

Check each layer in turn.

```bash
# 1. Is the Service actually a NodePort on 30090?
kubectl get svc -n monitoring kube-prometheus-stack-prometheus
# PORT(S) should read 9090:30090/TCP

# 2. Did kind actually publish the port?
docker port monitoring-control-plane
# should include 30090/tcp -> 0.0.0.0:9090

# 3. Is something else already on 9090?
ss -tulpn | grep 9090
```

If step 2 shows nothing, the cluster was created without `kind/cluster.yaml`.
`extraPortMappings` can't be added to a live cluster — recreate it:

```bash
make down && make cluster && make monitoring
```

If step 3 shows a conflict, either stop the other process or move Prometheus to
a free port: change `hostPort` in `kind/cluster.yaml`, the `url` in
`grafana/provisioning/datasources/prometheus.yaml`, and export
`PROM_HOST_PORT`. All three must agree.

**Quick unblock:** `make port-forward` gets you working immediately without
recreating anything.

---

## Grafana shows "Bad Gateway" or the datasource test fails

Grafana can reach port 3000 fine but not Prometheus. Almost always a
container-to-host networking issue.

Test from inside the container:

```bash
docker exec grafana-local wget -qO- http://host.docker.internal:9090/-/ready
```

**If that fails but `curl localhost:9090` works on your host**, then
`host.docker.internal` isn't resolving. Options:

1. Confirm `extra_hosts: ["host.docker.internal:host-gateway"]` is in
   `grafana/docker-compose.yml`. It is by default. Requires Docker 20.10+.
2. Use the docker0 bridge IP instead:
   ```bash
   ip -4 addr show docker0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}'   # e.g. 172.17.0.1
   ```
   Put that IP in the datasource `url`, then `make restart-grafana`.
3. **Best option — put Grafana on kind's network** and skip the host entirely:

   ```yaml
   # grafana/docker-compose.yml
   services:
     grafana:
       # ...
       networks: [kind]
   networks:
     kind:
       external: true
   ```

   ```yaml
   # grafana/provisioning/datasources/prometheus.yaml
   url: http://monitoring-control-plane:30090
   ```

   Then `make restart-grafana`. This also lets you set `listenAddress:
   "127.0.0.1"` in `kind/cluster.yaml` so Prometheus isn't exposed to your LAN.

**If you're running Grafana as a native binary**, the URL must be
`http://localhost:9090` — `host.docker.internal` means nothing outside a
container.

---

## Panels say "Datasource ${DS_PROMETHEUS} was not found"

The dashboard JSON reached Grafana without the datasource placeholder being
substituted. Re-run the fetch script:

```bash
make dashboards
make restart-grafana
```

If it persists on a dashboard you added by hand, the UID in the JSON doesn't
match the provisioned datasource. Every datasource reference must be:

```json
"datasource": { "type": "prometheus", "uid": "prometheus" }
```

Full explanation in [dashboards.md](dashboards.md#the-provisioning-gotcha).

---

## Dashboards load but panels are empty

Prometheus is reachable but has no data for those queries.

```bash
# Any healthy targets at all?
make targets

# Is kube-state-metrics producing data? (drives most pod/deployment panels)
curl -s 'http://localhost:9090/api/v1/query?query=count(kube_pod_info)'

# Is cAdvisor producing data? (drives CPU/memory panels)
curl -s 'http://localhost:9090/api/v1/query?query=count(container_memory_working_set_bytes)'
```

If `kube_pod_info` returns nothing, kube-state-metrics isn't being scraped:

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=kube-state-metrics
kubectl logs -n monitoring -l app.kubernetes.io/name=kube-state-metrics
```

If targets exist but are DOWN, open http://localhost:9090/targets — the error
column tells you exactly what failed.

Also check the time range. A fresh install has minutes of data; a dashboard
defaulting to "Last 7 days" looks empty. Switch to "Last 15 minutes".

---

## Some targets are permanently DOWN

Expected if you enabled control-plane monitoring — see the next section. For
anything else, the Targets page error message is the fastest path:

```bash
curl -s http://localhost:9090/api/v1/targets \
  | jq -r '.data.activeTargets[] | select(.health=="down") | "\(.labels.job)\t\(.lastError)"'
```

---

## Enabling control-plane metrics on kind

Off by default because kind binds these to `127.0.0.1` inside the node
container, where Prometheus can't reach them. To turn them on you must patch
the bind addresses at cluster creation — it can't be done afterwards.

**Check your kubeadm API version first.** The `extraArgs` syntax changed:
Kubernetes 1.31+ uses kubeadm `v1beta4` (list of name/value objects), earlier
versions use `v1beta3` (a map). Getting this wrong makes cluster creation fail.

```bash
kubectl version --short   # or check the node image tag in kind/cluster.yaml
```

**For Kubernetes 1.31+ (v1beta4):**

```yaml
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        controllerManager:
          extraArgs:
            - name: bind-address
              value: "0.0.0.0"
        scheduler:
          extraArgs:
            - name: bind-address
              value: "0.0.0.0"
        etcd:
          local:
            extraArgs:
              - name: listen-metrics-urls
                value: "http://0.0.0.0:2381"
```

**For Kubernetes 1.30 and earlier (v1beta3):**

```yaml
kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    controllerManager:
      extraArgs:
        bind-address: "0.0.0.0"
    scheduler:
      extraArgs:
        bind-address: "0.0.0.0"
    etcd:
      local:
        extraArgs:
          listen-metrics-urls: "http://0.0.0.0:2381"
```

kube-proxy is separate — add at the top level of `kind/cluster.yaml`, not under
a node:

```yaml
kubeadmConfigPatches:
  - |
    kind: KubeProxyConfiguration
    metricsBindAddress: "0.0.0.0"
```

Then flip the four `enabled: false` flags to `true` in
`helm/values-kube-prometheus-stack.yaml`, and recreate:

```bash
make down && make up
```

---

## `docker: permission denied` / `Cannot connect to the Docker daemon`

```bash
sudo usermod -aG docker $USER
```

Then **log out and back in** — group membership only applies to new sessions.
`newgrp docker` works for the current shell as a stopgap.

---

## Helm install times out

The `--wait --timeout 15m` in the install script is generous, but slow networks
can exceed it. The release usually finishes anyway; check:

```bash
helm status kube-prometheus-stack -n monitoring
make pods
```

If it's genuinely stuck, clear and retry:

```bash
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete ns monitoring
make monitoring
```

CRDs are intentionally left behind by `helm uninstall`. That's fine — reinstall
reuses them. To truly remove them:

```bash
kubectl get crd | grep -E 'monitoring.coreos.com' | awk '{print $1}' | xargs kubectl delete crd
```

---

## Starting completely over

```bash
make down
docker system prune -f
make up
```

`make down` deletes the cluster, its PVCs, and the Grafana volume. Nothing here
is meant to hold data you care about.
