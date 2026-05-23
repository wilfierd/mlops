# P6 — QA endpoint smoke test

Prerequisites: P5 (ingest pipeline running, at least 1 doc in `ready` state).

## 1. Deploy

P6 ships in the same `RagApi` Ray Serve deployment as P5 — no new Kubernetes manifests.
Rebuild and push the app image, then rolling-update the RayService:

```bash
make -C infra push          # docker build + ECR push
make -C infra rag-up        # re-applies k8s/rayservice.yaml with new image + VLLM_BASE_URL

# Port-forward (if not already running)
make -C infra rag-pf &
sleep 3
curl -s http://localhost:8000/healthz
# Expect: {"status":"ok"}
```

## 2. Happy-path QA

```bash
# Ingest a test doc first (if none ready)
DOC_ID=$(curl -s -X POST http://localhost:8000/documents \
  -F "file=@/path/to/test.pdf" | jq -r .doc_id)

# Wait until ready
watch -n 3 "curl -s http://localhost:8000/documents/$DOC_ID | jq .status"
# → "ready"

# Ask a question
curl -s -X POST http://localhost:8000/qa \
  -H 'content-type: application/json' \
  -d '{"question": "Nội dung chính của tài liệu là gì?"}' | jq .
# Expect:
# {
#   "answer": "<non-empty Vietnamese answer>",
#   "sources": [{"doc_id":..., "doc_title":..., "chunk_idx":..., "score":..., "text":...}, ...],
#   "latency_ms": {"embed":..., "qdrant":..., "mmr":..., "llm":..., "total":...},
#   "fallback_reason": null
# }
```

## 3. Scope-to-doc QA

```bash
# Limit retrieval to a specific document
curl -s -X POST http://localhost:8000/qa \
  -H 'content-type: application/json' \
  -d "{\"question\": \"Tóm tắt nội dung\", \"doc_ids\": [\"$DOC_ID\"], \"top_k\": 3}" | jq .
# Expect: sources all have doc_id == $DOC_ID
```

## 4. No-context fallback

```bash
# Question that has no relevant chunks
curl -s -X POST http://localhost:8000/qa \
  -H 'content-type: application/json' \
  -d '{"question": "Giá cổ phiếu Apple hôm nay là bao nhiêu?", "score_threshold": 0.9}' | jq .
# Expect: fallback_reason="no_hits", answer="Tôi không tìm thấy thông tin trong tài liệu."
```

## 5. Validation edge cases

```bash
# Too short
curl -s -X POST http://localhost:8000/qa \
  -H 'content-type: application/json' \
  -d '{"question": "ok"}' | jq .
# Expect: 400 detail="question_too_short"

# doc_id not ready
curl -s -X POST http://localhost:8000/qa \
  -H 'content-type: application/json' \
  -d '{"question": "test", "doc_ids": ["nonexistent00"]}' | jq .
# Expect: 400 detail="doc_not_ready: nonexistent00"
```

## 6. Latency check (cost-first profile, T4)

```bash
# Single warm request
time curl -s -X POST http://localhost:8000/qa \
  -H 'content-type: application/json' \
  -d '{"question": "Câu hỏi thực tế từ tài liệu"}' | jq .latency_ms
# Expect: total ≤ 18 000 (ms) on g4dn.xlarge cost-first profile
# embed ~100ms, qdrant ~50ms, mmr ~1ms, llm ~5000–18000ms
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `503 S3_BUCKET not configured` | Env var not injected | Check `make rag-up` ran after `make persistent-apply` |
| `503 embedder not ready: TimeoutError` | Embedder actor not up yet | Wait 60s after pod Running; check `ray status` |
| `llm_timeout` in fallback_reason | vLLM slow or not running | Check `kubectl -n llm-chat logs vllm-server-0`; verify GPU node Ready |
| `qdrant_timeout` | Qdrant not reachable | `kubectl -n llm-chat get pod qdrant-0`; check `make -C infra qdrant-pf` |
| `no_hits` on valid question | score_threshold too high or doc not ingested | Lower `score_threshold` to 0.3; verify `GET /documents/$DOC_ID` is `ready` |
| Empty `answer` with `fallback_reason=null` | vLLM returned empty completion | Check vLLM args `--served-model-name=qwen-rag` and model loaded |
| `429 busy_try_again` | 16 concurrent in-flight | Reduce concurrency; `QA_INFLIGHT` semaphore cap 16 |
| `400 doc_not_ready` | Doc still processing | `GET /documents/{doc_id}` and wait for `status=ready` |
| `connection refused` on vLLM | `VLLM_BASE_URL` wrong | `kubectl -n llm-chat exec <ray-head> -- curl -s http://vllm-server-0.vllm-server.llm-chat.svc.cluster.local:8000/health` |
