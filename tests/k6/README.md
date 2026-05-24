# k6 performance tests for RAG /qa

Targets the current architecture (Ray Serve RagApi + vLLM Qwen2.5-3B-AWQ on T4 +
Qdrant) via the `/qa` endpoint. Replaces the legacy `/chat` CPU model tests.

## What you should know before running

Hard limits in the deployed stack:

| Limit | Value | Source |
| --- | --- | --- |
| `RagApi` replicas             | autoscale 1→2 | `k8s/rayservice.yaml` |
| `RagApi.max_ongoing_requests` | 8 per replica | `k8s/rayservice.yaml` |
| `QA_INFLIGHT` semaphore       | 16 | `app/rag_server.py` (returns 429 on overflow) |
| vLLM replicas                 | 2 x T4 GPU pods | `k8s/vllm-server.yaml` |
| `vllm --max-num-seqs`         | 8 per pod | `k8s/vllm-server.yaml` |
| `vllm --max-model-len`        | 8192 | same |
| `QA_MAX_TOKENS`               | 160 | env in `rayservice.yaml` |

So: ~16 concurrent decoding requests is the design ceiling across 2 GPUs. Past that, the app
intentionally returns HTTP 429 (`fallback_reason=backpressure`) rather than queue.

## Suites

| Suite | VUs | Duration | What it answers |
| --- | --- | --- | --- |
| `k6-baseline.js` | 1 constant       | 2m  | Single-user p50/p95/p99 on T4+3B |
| `k6-load.js`     | 4 constant       | 5m  | Demo audience on 2-GPU scale-out |
| `k6-stress.js`   | 1→20 ramp + hold | 15m | Where backpressure kicks in |
| `k6-spike.js`    | 0→16 step        | 10m | TTFT degradation under cold-batch warmup |

## Custom metrics emitted

Defined in `helpers.js`:

- `qa_duration_ms` — wall-clock per request (k6 client side).
- `qa_ttft_ms`     — server-reported TTFT (from `latency_ms.ttft`).
- `qa_decode_ms`   — server-reported decode time (`latency_ms.decode`).
- `qa_error_rate`  — fraction of requests that failed strict assertions.
- `qa_slow_rate`   — fraction over 10s wall time.
- `qa_fallback_total{reason=...}` — counter tagged by `no_hits`, `embed_timeout`, `qdrant_timeout`, `llm_timeout`, `empty_answer`, `backpressure`.
- `qa_backpressure_total` — HTTP 429 count.
- `qa_empty_answer_total` — 200 with empty `answer` and no `fallback_reason`.

## Prereqs

```bash
# Install k6
sudo dnf install k6      # Fedora
brew install k6          # macOS
```

## Run

```bash
# Terminal 1: port-forward once
kubectl -n llm-chat port-forward svc/llm-chat-serve-svc 8000:8000

# Terminal 2: run any suite
k6 run tests/k6/k6-baseline.js
k6 run tests/k6/k6-load.js
k6 run tests/k6/k6-stress.js
k6 run tests/k6/k6-spike.js
```

`BASE_URL` defaults to `http://127.0.0.1:8000`. Override for ALB / public:

```bash
k6 run -e BASE_URL=https://chat.example.com tests/k6/k6-load.js
```

Other env knobs (in `helpers.js`):

```bash
k6 run -e TOP_K=5 -e SCORE_THRESHOLD=0.4 tests/k6/k6-load.js
```

## What to watch while a test runs

```bash
# Terminal A: live pod state
kubectl -n llm-chat get pods -w

# Terminal B: Grafana
kubectl -n monitoring port-forward svc/kube-prom-stack-grafana 3000:80
# http://127.0.0.1:3000 → Dashboards → RAG Pipeline

# Terminal C: structured /qa log (1 JSON line per request)
kubectl -n llm-chat logs -f $(kubectl -n llm-chat get pod -l ray.io/node-type=head -o name) -c ray-head \
  | grep -E '"event":"qa_request"' | jq -r '[.request_id, .status, .latency_ms.total, .completion_tokens] | @tsv'

# Terminal D: k6 run
k6 run tests/k6/k6-stress.js
```

Grafana panels that move under stress/spike:

- **QA In-Flight Requests** — should hit 16 ceiling and hold.
- **QA Fallback Rate by Reason** — `backpressure` line should appear in stress at VU>16.
- **vLLM Queue Depth (waiting/running)** — `waiting>0` is the precise signal of vLLM saturation.
- **vLLM TTFT** — spikes during the first 30s of spike test, recovers.
- **QA Per-Step p95 Latency** — `llm` step dominates; embed/qdrant/mmr should stay flat.

## Wrapper script (audit-trail evidence)

`run-local.sh` does port-forward + before/after cluster snapshots + JSON
export into `reports/k6-<suite>-<timestamp>/`. Use when you want a record of
the run (eval evidence, capacity-planning report).

```bash
./tests/k6/run-local.sh baseline
PROM_SNAPSHOT=1 ./tests/k6/run-local.sh stress   # also dump vllm /metrics
```

For day-to-day iteration the wrapper is overkill — plain `k6 run` is fine.

## Tracing a single k6 request in app logs

Every request sends `X-Request-Id: k6-<rand>-vu<N>-it<N>`. Grep the structured
log for that prefix to pull the per-request observability fields (top_score,
completion_tokens, ttft, decode):

```bash
make rag-logs | grep '"request_id":"k6-' | jq .
```

## Comparing runs

```bash
k6 run --summary-export reports/baseline.json tests/k6/k6-baseline.js
k6 run --summary-export reports/load.json     tests/k6/k6-load.js

for r in reports/*.json; do
  echo "== $r =="
  jq '.metrics.qa_duration_ms.values | {"p(50)", "p(95)", "p(99)", count}' "$r"
  jq '.metrics.qa_ttft_ms.values     | {"p(50)", "p(95)"}'                 "$r"
done
```

## Tuning load profile

`options.stages` durations are short for lab iteration. Bump in the .js file
for a real benchmark publish. To change the question pool, edit `QUESTIONS`
in `helpers.js` — keep them aligned with `data/seed/*.md` so retrieval has
real hits.

## Port-forward fidelity caveat

`kubectl port-forward` adds ~10–20 ms per request (single SPDY tunnel) and
serializes traffic through one local process. Fine for relative comparison
across runs. For absolute numbers worth publishing, deploy k6 as a K8s Job
in-cluster.
