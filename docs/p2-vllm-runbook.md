# P2 — vllm-openai deploy + smoke bench

End-to-end runbook for bringing the LLM server up and verifying it on a freshly-applied ephemeral cluster.

## Prerequisites

- `persistent/` stack applied (creates EBS `llm-cache` + ECR + S3 + VPC).
- `cluster-up` ran successfully (EKS + node groups + EBS CSI + NVIDIA plugin + PVs bound).

```bash
make -C infra cluster-status
# Expect:
#   head    Ready  node-type=head
#   gpu     Ready  node-type=gpu-worker  nvidia.com/gpu=true
kubectl -n llm-chat get pvc
# Expect llm-cache-pvc to be Pending (WaitForFirstConsumer) — vllm pod will bind it
```

## 1. Deploy

```bash
make -C infra vllm-up
```

What happens (cost-first profile on g4dn.xlarge, ~5–8 min cold):

1. `kubectl apply -f k8s/vllm-server.yaml` — creates Service + StatefulSet
2. K8s schedules pod onto the GPU node (taint toleration + nodeSelector)
3. PVC `llm-cache-pvc` binds to retained EBS `vol-...`
4. Image pull `vllm/vllm-openai:v0.11.0` (~7 GiB upstream → 90–180 s first time)
5. `vllm` starts → downloads Qwen2.5-7B-AWQ (~5 GB) from HF into `/models/hf-cache` (PVC → EBS, persists across cluster destroy)
6. AWQ kernel warmup + CUDA graph capture (~30 s on T4)
7. Readiness probe goes green → `kubectl wait` returns

Subsequent `cluster-up` after the first session: model is on EBS llm-cache → cold start drops to ~2 min.

## 2. Smoke-check the server

```bash
# Terminal A — leave it running
make -C infra vllm-pf

# Terminal B
curl -s http://localhost:8000/v1/models | jq .
# Expect: {"object":"list","data":[{"id":"qwen-rag", ...}]}

curl -s http://localhost:8000/health
# Expect: 200 OK

# Direct chat
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "qwen-rag",
    "messages": [{"role":"user","content":"Trả lời ngắn: 2+2 là?"}],
    "max_tokens": 50
  }' | jq .
# Expect: usage.prompt_tokens + completion_tokens > 0
```

If `/v1/models` returns the served name but `/health` keeps 503 → the engine is still loading. Tail logs:

```bash
make -C infra vllm-logs
# Look for: "INFO ... AsyncLLMEngine ... Model loaded"
#           "INFO ... Application startup complete"
```

## 3. Bench (RAG-shaped prompts)

```bash
make -C infra vllm-bench
# Or with custom params:
python3 scripts/bench_vllm.py \
    --concurrency 1,4 \
    --requests 10 \
    --prompt-tokens 3000 \
    --new-tokens 200 \
    --out reports/p2-vllm-bench.md
```

### Expected ballpark — cost-first T4 (g4dn.xlarge)

Bench reports BOTH per-request latency breakdown (TTFT = prefill, e2e − TTFT = decode) AND aggregate system throughput.

| Metric | Target | Note |
|---|---:|---|
| TTFT p50 (c=1, 3K prompt) | **4–8 s** | T4 prefill ~400–800 tok/s |
| TTFT p95 (c=1) | < 10 s | warmed |
| Decode tok/s p50 (c=1) | **20–30 tok/s** | T4 single-stream |
| `/chat` e2e p50 (c=1, 3K + 200) | **10–16 s** | TTFT + decode |
| `/chat` e2e p95 (c=1) | **< 18 s** | matches cost-first SLA doc §5 |
| `/chat` e2e p95 (c=4) | **< 25 s** | shared GPU |
| system tok/s (c=4) | > 80 tok/s | sum across in-flight |
| 0 failed requests | yes | no timeouts under this profile |

If you hit OOM or HTTP 5xx:

- `kubectl -n llm-chat logs vllm-server-0 --previous` — check for `CUDA out of memory`
- Reduce `--max-num-seqs` to 2 in `k8s/vllm-server.yaml` and re-apply
- Or reduce `--max-model-len` to 3072

### If you're on stable profile (g6.xlarge / g5.xlarge)

| Metric | Target |
|---|---:|
| TTFT p50 (c=1, 3K) | **1.5–3 s** |
| Decode tok/s p50 (c=1) | **60–90 tok/s** |
| p50 e2e (c=1, 3K + 200) | **5–9 s** |
| p95 e2e (c=1) | < 12 s |
| p95 e2e (c=4) | < 15 s |
| system tok/s (c=4) | > 200 tok/s |

Stable args (already in `k8s/vllm-server.yaml` as comments) to swap in:

```yaml
- "--quantization=awq_marlin"
- "--kv-cache-dtype=fp8_e5m2"
- "--max-model-len=8192"
- "--max-num-seqs=16"
```

## 4. Tear down (keep model cache)

```bash
make -C infra vllm-down
```

This deletes the StatefulSet + Service but **NOT** the `llm-cache-pvc` (it's part of the ephemeral stack, but bound to a retained EBS volume in persistent). Next `vllm-up` reuses the cached model.

For a full session teardown:

```bash
make -C infra cluster-down
```

EBS `llm-cache` survives — next cluster-up will see model already cached.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Pod stuck `Pending` "Insufficient nvidia.com/gpu" | GPU node not Ready, OR device plugin not running, OR wrong AMI | `kubectl get nodes -L node-type,nvidia.com/gpu` + `kubectl -n kube-system logs ds/nvidia-device-plugin-daemonset` |
| PVC stuck `Pending` after pod schedules | EBS CSI IRSA not wired | `kubectl -n kube-system logs deploy/ebs-csi-controller -c csi-provisioner` |
| First model download times out at HF | NAT disabled + IGW not reachable | Check that node has public IP (`kubectl get node -o wide`). If not, persistent stack wasn't applied with `workers_in_public_subnet`. |
| `CUDA out of memory` during decode | `max_num_seqs` too high for T4 KV budget | Lower to 2 or reduce `max_model_len` |
| Slow first-token latency stays high after warmup | CUDA graph not capturing | Remove `--enforce-eager=false` (default — leave as-is); check that pod has `nvidia.com/gpu=1` allocatable |
