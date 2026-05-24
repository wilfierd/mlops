# P8 Observability — Runbook

## Tổng Quan

P8 thêm vào stack monitoring:
- **Qdrant PodMonitor** — scrape `/metrics` port 6333
- **vLLM PodMonitor** — scrape `/metrics` port 8000
- **RAG pipeline dashboard** — 12 panel Grafana, QA latency / fallback / vLLM / Qdrant
- **App metrics** (`app/metrics.py`) — Counter/Histogram/Gauge từ `ray.util.metrics` emitted qua Ray :8080
- **ops_node_selector** — pin Prometheus + Grafana pods sang node group ops

## Prerequisites

```
# Cluster running (P0–P4 complete)
kubectl get rayservice -n llm-chat llm-chat
# observability module deployed
kubectl get pods -n monitoring
```

## Deploy

```bash
cd infra/environments/dev/ephemeral
terraform apply -target=module.observability
```

## Verify Metrics Scraping

### Ray metrics (existing)
```bash
kubectl port-forward -n llm-chat svc/llm-chat-head-svc 8080:8080
curl -s http://localhost:8080/metrics | grep rag_qa
# Expected: rag_qa_requests_total, rag_qa_latency_ms_bucket, ...
```

### Qdrant metrics (new)
```bash
kubectl port-forward -n llm-chat svc/qdrant 6333:6333
curl -s http://localhost:6333/metrics | grep qdrant_points_count
```

### vLLM metrics (new)
```bash
kubectl port-forward -n llm-chat svc/vllm-server 8000:8000
curl -s http://localhost:8000/metrics | grep vllm
```

### Prometheus scrape status
```bash
kubectl port-forward -n monitoring svc/kube-prom-stack-prometheus 9090:9090
# Open http://localhost:9090/targets
# Confirm: ray-head-metrics, qdrant-metrics, vllm-metrics all UP
```

## Grafana Dashboard

```bash
kubectl port-forward -n monitoring svc/kube-prom-stack-grafana 3000:80
# Open http://localhost:3000
# Login: admin / <grafana_password output from terraform>
# Navigate: Dashboards → RAG Pipeline
```

Dashboard panels:
| Panel | Metric | Alert threshold |
|-------|--------|----------------|
| QA E2E Latency | `rag_qa_latency_ms` | p95 > 20s = warning |
| QA Request Rate | `rag_qa_requests_total` | error rate > 5% |
| Per-Step p95 | `rag_qa_step_latency_ms` | llm p95 > 15s |
| Fallback Rate | `rag_qa_fallback_total` | no_hits > 20% |
| QA In-Flight | `rag_qa_inflight` | > 14 (near semaphore limit of 16) |
| Doc Upload Rate | `rag_ingest_docs_total` | — |
| Chunk Throughput | `rag_ingest_chunks_total` | — |
| vLLM Queue | `vllm:num_requests_waiting` | > 10 sustained |
| vLLM Tokens | `vllm:generation_tokens_total` | — |
| Qdrant Search p95 | `qdrant_collection_search_duration_seconds` | > 200ms |
| Qdrant Points | `qdrant_points_count` | — |

## Troubleshooting

### Metrics không xuất hiện trong Prometheus

1. Kiểm tra PodMonitor được tạo:
```bash
kubectl get podmonitor -n monitoring
# Expected: qdrant-metrics, vllm-metrics
```

2. Kiểm tra Prometheus có discover targets:
```bash
# http://localhost:9090/targets — tìm "qdrant" và "vllm"
# Nếu không thấy: check namespaceSelector trong PodMonitor
```

3. Kiểm tra pod labels match selector:
```bash
kubectl get pods -n llm-chat -l app=qdrant
kubectl get pods -n llm-chat -l app=vllm-server
```

### Ray custom metrics (rag_qa_*) không xuất hiện

Ray custom metrics được emit bởi actor (RagApi replica). Metrics chỉ xuất hiện sau lần gọi đầu tiên.

```bash
curl -s http://localhost:8000/healthz  # trigger actor init
curl -s http://localhost:8000/qa -d '{"question":"test"}' -H Content-Type:application/json
# Sau đó check: curl http://localhost:8080/metrics | grep rag_
```

Nếu vẫn không thấy: kiểm tra Ray version ≥ 2.3 (ray.util.metrics Counter/Histogram/Gauge).

### Dashboard không import

Sidecar Grafana cần label `grafana_dashboard=1` trên ConfigMap:
```bash
kubectl get configmap -n monitoring -l grafana_dashboard=1
# Expected: grafana-dashboard-rag-pipeline, grafana-dashboard-ray-cluster-ops, grafana-dashboard-llm-chat-app
```

Nếu thiếu: `terraform apply -target=module.observability` lại sau khi grafana pod restart.

## ops_node_selector

Để chạy Prometheus + Grafana trên node ops riêng, truyền biến khi apply:

```hcl
# infra/environments/dev/ephemeral/main.tf
module "observability" {
  source             = "../../../modules/observability"
  ops_node_selector  = { "node-type" = "ops" }
  ...
}
```

Node ops cần taint/toleration tương ứng hoặc không có taint (chỉ dùng nodeSelector).
