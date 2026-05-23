# P5 — Ingest pipeline smoke test

Prerequisites: P3 (Qdrant ready) + P4 (RAG service running with image pushed via `make push`).

## 1. Deploy

```bash
make -C infra rag-up
# Injects APP_IMAGE + S3_BUCKET from persistent TF outputs.
# Waits for KubeRay operator, then applies k8s/rayservice.yaml.

# Monitor startup (~2–3 min first time):
kubectl -n llm-chat get rayservice,pods -w
# Expect: rayservice/llm-chat READY=True; ray-head pod Running

# Port-forward
make -C infra rag-pf &
sleep 3
curl -s http://localhost:8000/healthz
# Expect: {"status":"ok"}
```

## 2. Upload a document

```bash
# Upload a small PDF
curl -s -X POST http://localhost:8000/documents \
  -F "file=@/path/to/test.pdf" | jq .
# Expect: {"doc_id":"<16hex>","status":"processing"}

DOC_ID=<paste doc_id here>

# Poll until ready (< 60s for 50-page PDF)
watch -n 3 "curl -s http://localhost:8000/documents/$DOC_ID | jq .status"
# Expect: "processing" → "ready"
```

## 3. Verify ingest

```bash
# Check doc status
curl -s http://localhost:8000/documents/$DOC_ID | jq .
# Expect: {doc_id, status:"ready", num_chunks:N, completed_at:...}

# Check Qdrant points (needs qdrant-pf running on :6333)
make -C infra qdrant-pf &
sleep 2
curl -s -X POST http://localhost:6333/collections/documents/points/count \
  -H 'content-type: application/json' \
  -d '{"exact":true}' | jq .result.count
# Expect: N (matches num_chunks from status above)
```

## 4. Idempotency check

```bash
# Re-upload same file — must return 200 "ready", NOT re-ingest
curl -s -X POST http://localhost:8000/documents \
  -F "file=@/path/to/test.pdf" | jq .
# Expect: {"doc_id":"<same hex>","status":"ready","num_chunks":N}

# Point count must be unchanged
curl -s -X POST http://localhost:6333/collections/documents/points/count \
  -H 'content-type: application/json' -d '{"exact":true}' | jq .result.count
# Expect: same N as before
```

## 5. List + delete

```bash
# List all docs
curl -s http://localhost:8000/documents | jq '.[] | {doc_id, status, filename}'

# Soft-delete
curl -s -X DELETE http://localhost:8000/documents/$DOC_ID
# Expect: HTTP 204 No Content

# Verify Qdrant vectors removed
curl -s -X POST http://localhost:6333/collections/documents/points/count \
  -H 'content-type: application/json' -d '{"exact":true}' | jq .result.count
# Expect: 0 (or N minus deleted doc's chunks)

# GET should 404 now
curl -s http://localhost:8000/documents/$DOC_ID | jq .
# Expect: {"detail":"document not found"}
```

## 6. Re-upload after delete (resurrection path)

```bash
curl -s -X POST http://localhost:8000/documents \
  -F "file=@/path/to/test.pdf" | jq .
# Expect: 202 {"status":"processing"} — resurrects and re-ingests
```

## 7. Reaper test (stuck-processing simulation)

```bash
# Manually write a stuck meta entry
python3 - <<'EOF'
import boto3, json
from datetime import datetime, timezone, timedelta

bucket = "YOUR_BUCKET"
doc_id = "deadbeef00000000"
s3 = boto3.client("s3")
s3.put_object(
    Bucket=bucket,
    Key=f"meta/{doc_id}.json",
    Body=json.dumps({
        "doc_id": doc_id, "status": "processing",
        "started_at": (datetime.now(timezone.utc) - timedelta(minutes=15)).isoformat(),
        "filename": "stuck-test.pdf",
    }).encode(),
    ContentType="application/json",
)
print(f"planted stuck doc {doc_id}")
EOF

# Wait up to 5 min for reaper to run, or restart rag-pf and check GET:
curl -s http://localhost:8000/documents/deadbeef00000000 | jq .status
# Expect: "failed" (after reaper fires) or still "processing" (wait longer)
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `503 S3_BUCKET not configured` | `__S3_BUCKET__` not replaced | Verify `make rag-up` ran after `make persistent-apply`; check pod env: `kubectl -n llm-chat exec <ray-head> -- env \| grep S3` |
| Status stuck at `processing` after > 10 min | Ray Task crashed silently | Check ray-head logs: `make -C infra rag-logs \| grep ERROR`; reaper will fire at 5 min mark |
| Status `failed` with `error_code: pdf_no_text_layer` | Scanned image PDF | Convert with OCR (e.g. `ocrmypdf`) before uploading |
| `415 unsupported_mime` on valid PDF | `filetype` misidentified bytes | Check actual magic bytes: `file yourfile.pdf` |
| Qdrant count grows on re-upload | Dedup not working — S3 meta read failed | Check `meta_read` logs; verify IAM role has `s3:GetObject` on `meta/*` |
| `ingest_task` can't reach Qdrant | Wrong `QDRANT_HOST` or pod DNS | `kubectl -n llm-chat exec <ray-head> -- curl -s http://qdrant-0.qdrant.llm-chat.svc.cluster.local:6333/readyz` |
