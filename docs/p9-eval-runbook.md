# P9 Eval + Seed Data — Runbook

## Tổng Quan

P9 cung cấp:
- **3 seed documents** (`data/seed/`) — Vietnamese/English markdown về RAG, Qdrant, Ray Serve với facts có thể kiểm tra
- **20 eval questions** (`data/eval/eval_questions.jsonl`) — câu hỏi có expected_keywords, doc_source, score_threshold
- **Eval runner** (`scripts/eval_qa.py`) — upload docs → poll ready → gọi /qa → keyword check → latency report

## Prerequisites

```bash
pip install httpx  # eval script dependency

# Cluster running with:
# - RAG API accessible (port-forward hoặc LoadBalancer)
# - S3_BUCKET configured
# - Qdrant running
# - vLLM running (cho câu trả lời có nội dung)
```

## Chạy Eval

### Happy path (upload + eval)
```bash
# Port-forward RAG API nếu cần
kubectl port-forward -n llm-chat svc/llm-chat-serve-svc 8000:8000 &

python scripts/eval_qa.py \
    --base-url http://localhost:8000 \
    --seed-dir data/seed \
    --eval-file data/eval/eval_questions.jsonl \
    --output-json /tmp/eval_results.json
```

### Skip upload (docs đã được index)
```bash
python scripts/eval_qa.py \
    --base-url http://localhost:8000 \
    --skip-upload \
    --eval-file data/eval/eval_questions.jsonl
```

### Tùy chỉnh pass rate threshold
```bash
# Default: fail nếu pass rate < 70%
python scripts/eval_qa.py --min-pass-rate 0.8
```

## Output Mẫu

```
=== Uploading seed documents ===
  uploaded 01_rag_concepts.md → doc_id=a1b2c3d4e5f60001 status=processing
  uploaded 02_qdrant_guide.md → doc_id=f9e8d7c6b5a40002 status=processing
  uploaded 03_ray_serve_guide.md → doc_id=1a2b3c4d5e6f0003 status=processing

=== Waiting for ingest to complete ===
  a1b2c3d4e5f60001 ready
  f9e8d7c6b5a40002 ready
  1a2b3c4d5e6f0003 ready

=== Running eval from data/eval/eval_questions.jsonl ===
  [q01] PASS | total=3420ms
  [q02] PASS | total=4100ms
  [q03] PASS | total=5230ms
  [q04] PASS | total=2890ms
  [q05] FAIL | total=3100ms missing=['passage:']
  ...

=== Results ===
Total questions : 20
Passed          : 15/20 (75.0%)
Latency p50     : 3800ms
Latency p95     : 14200ms
```

Exit code: 0 nếu pass_rate ≥ min-pass-rate, 1 nếu thấp hơn.

## Seed Documents

| File | Nội dung | Số câu eval |
|------|---------|-------------|
| `01_rag_concepts.md` | RAG pipeline, cosine similarity, MMR, chunking, embedding models, latency budget | 10 |
| `02_qdrant_guide.md` | Point structure, distance metrics, query_points API, HNSW params, RAM estimation, Prometheus metrics | 6 |
| `03_ray_serve_guide.md` | Deployment decorator, DeploymentHandle, KubeRay, autoscaling, metrics port, serviceUnhealthySecondThreshold | 6 |

## Eval Question Format

```jsonl
{
  "id": "q01",
  "question": "RAG là viết tắt của gì và gồm mấy bước chính?",
  "expected_keywords": ["Retrieval-Augmented Generation", "retrieval", "generation", "5"],
  "doc_source": "01_rag_concepts.md",
  "score_threshold": 0.5
}
```

- `expected_keywords`: tất cả phải xuất hiện trong answer (case-insensitive) để PASS
- `doc_source`: tên file seed chứa câu trả lời (informational only, không dùng để filter)
- `score_threshold`: ngưỡng để câu hỏi được tính là câu hỏi "khó" (không dùng trong script hiện tại)

## Pass/Fail Targets

| Metric | Target tối thiểu | Target tốt |
|--------|-----------------|-----------|
| Pass rate | ≥ 70% | ≥ 85% |
| Latency p50 | ≤ 8s | ≤ 4s |
| Latency p95 | ≤ 18s | ≤ 12s |
| Fallback rate | ≤ 30% | ≤ 10% |

## Troubleshooting

### Pass rate thấp (< 70%)

**Nguyên nhân phổ biến:**
1. **LLM không trả lời bằng tiếng Việt** — kiểm tra `VLLM_BASE_URL` trỏ đúng model qwen
2. **Qdrant không trả về chunk** — kiểm tra `score_threshold` trong QARequest (default 0.5 có thể quá cao)
3. **Ingest bị lỗi** — xem doc status: `curl http://localhost:8000/documents | jq .[].status`
4. **E5 prefix thiếu** — kiểm tra `"query: "` prefix trong `rag_server.py:469`

**Debug một câu:**
```bash
curl -X POST http://localhost:8000/qa \
    -H "Content-Type: application/json" \
    -d '{"question": "RAG là viết tắt của gì?", "top_k": 5}' | jq .
```

### Latency p95 > 18s

1. **LLM queue full** — vLLM đang xử lý nhiều request, check `vllm:num_requests_waiting`
2. **Cold start** — lần đầu sau deploy, actor chưa warm; chạy `/healthz` trước
3. **Qdrant slow** — check `qdrant_collection_search_duration_seconds` trong Grafana

### Ingest timeout (poll_until_ready raise TimeoutError)

Default timeout: 300s. Tài liệu markdown nhỏ nên ingest < 30s.

```bash
# Kiểm tra ingest task logs
kubectl logs -n llm-chat -l ray.io/node-type=head -c ray-head | grep -i ingest
```

Nếu doc status = "failed", xem `error_code` trong response.

## CI Integration

```yaml
# .github/workflows/eval.yml (ví dụ)
- name: Run RAG eval
  run: |
    python scripts/eval_qa.py \
      --base-url ${{ env.RAG_URL }} \
      --min-pass-rate 0.7 \
      --output-json eval-results.json
- name: Upload eval results
  uses: actions/upload-artifact@v3
  with:
    name: eval-results
    path: eval-results.json
```
