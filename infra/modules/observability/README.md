# observability

Installs `kube-prometheus-stack` (Prometheus + Grafana + kube-state-metrics +
node-exporter + CRDs) and wires Ray Serve metrics into it.

Status: P8 draft. This module is not wired into the default `dev/ephemeral`
stack yet. Before enabling it, update dashboards for the RAG/vLLM metrics and
schedule it on a dedicated `ops` node so it does not compete with the Ray head.

## What you get

- **Prometheus** scraping every K8s `ServiceMonitor` cluster-wide. Default
  retention is 6h (lab) — bump `prometheus_retention` for longer.
- **Grafana** with a pre-loaded `Ray Serve — LLM Chat` dashboard
  (`dashboards/ray-serve.json`). Sidecar auto-imports any ConfigMap labeled
  `grafana_dashboard=1` so you can ship more dashboards by adding ConfigMaps.
- **Alertmanager** disabled (lab) — flip in `main.tf` if needed.
- **ServiceMonitor** that scrapes any Ray pod's `metrics:8080/metrics`
  endpoint (KubeRay exposes it by default).

## Access

```bash
# Grafana — get the auto-generated password if you didn't set one
terraform output -raw grafana_admin_password
$(terraform output -raw port_forward_grafana_command)
# http://localhost:3000 — login admin / <password>

# Prometheus
$(terraform output -raw port_forward_prometheus_command)
# http://localhost:9090
```

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `namespace` | string | `monitoring` | Namespace to install into |
| `chart_version` | string | `65.1.1` | kube-prometheus-stack chart version |
| `ray_namespace` | string | `llm-chat` | Namespace where Ray pods live |
| `prometheus_retention` | string | `6h` | Metrics retention |
| `prometheus_memory` | string | `512Mi` | Prometheus memory request |
| `grafana_admin_password` | string | `""` (auto) | Empty = random generated |
| `persist_grafana` | bool | `false` | Use PVC for Grafana (needs EBS CSI) |

## Outputs

| Name | Description |
| --- | --- |
| `namespace` | Monitoring namespace name |
| `grafana_service_name` | Service name (`kube-prom-stack-grafana`) |
| `grafana_admin_password` | (sensitive) Initial admin password |
| `prometheus_service_name` | Prometheus service name |
| `port_forward_grafana_command` | Copy/paste port-forward command |
| `port_forward_prometheus_command` | Same for Prometheus |

## Dashboards

The default `dashboards/ray-serve.json` covers:

- Active Serve replica count
- Request rate (req/s) per route
- Ongoing requests per replica (drives Ray Serve autoscale)
- Latency p50 stat + p50/p95/p99 timeseries
- Error rate %
- CPU + memory per Ray pod (cAdvisor metrics)

To add more dashboards: drop a `<name>.json` next to the existing one and
mount it in `main.tf` as another `kubernetes_config_map` with label
`grafana_dashboard = "1"`.

## Resource budget

| Component | Memory request | CPU request |
| --- | --- | --- |
| Prometheus | 512Mi (configurable) | 250m (default chart) |
| Grafana | 100Mi | 100m |
| kube-state-metrics | 32Mi | 10m |
| node-exporter (DaemonSet) | 50Mi/node | 10m/node |
| Operator | 100Mi | 100m |

≈ 1Gi memory total + ~1 CPU. For the RAG cost-first profile, run this on the
optional `ops` node from P8 instead of packing it onto the `m6i.large` head.
