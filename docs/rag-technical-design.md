# RAG / Document Q&A — Technical Design

**Status:** draft (rev 2)
**Author:** mlops team
**Date:** 2026-05-23
**Reviewers:** —
**Scope:** Nâng cấp `llm-chat` (Ray Serve + KubeRay trên EKS) thành **Document Q&A Chatbot** (RAG) trong cùng cluster, giữ ràng buộc budget $100/tháng. Pivot hỗn hợp: **x86 head + GPU worker** (image cùng arch), bỏ ARM head vì incompat với CUDA image.

### Changelog rev 2 (2026-05-23) — sửa P0 từ review

1. **Head node ARM → x86** (`m6i.large`): Ray head + GPU worker phải cùng arch để share CUDA image. ARM Graviton head cũ (`t4g.large`) đã loại bỏ.
2. **Bỏ dedicated `vector-db` node group**: Qdrant collocate trên head x86. r7g.large overkill cho MVP 50 docs (~vài nghìn vectors). Tách lại khi > 100K vectors.
3. **vLLM: bỏ pin `0.6.3`** — dùng official image `vllm/vllm-openai:latest-stable` (CUDA + torch + autoawq đã build sẵn, tested combo).
4. **vLLM serving split**: chạy `vllm-openai` server riêng trên GPU pod, FastAPI/Ray gọi HTTP nội bộ — dễ debug, tách actor lifecycle khỏi engine.
5. **GPU candidates**: thêm `g6.xlarge` (NVIDIA L4 24GB, Ada arch, inference-oriented) làm primary alternative cạnh `g5.xlarge`. `g4dn` chỉ fallback rẻ.
6. **Phase plan reorder**: P1 = x86 EKS GPU skeleton + vLLM `/chat` benchmark trước khi đụng RAG (P3+).
7. **Note**: nâng retrieval (reranker / bge-m3) trước khi upgrade LLM lên 14B — retrieval quality là dominant factor cho RAG.

---

## 0. Executive summary

Hệ thống hiện tại phục vụ **chat ngắn** với Qwen3-0.6B Q4_K_M trên Ray Serve + Graviton3. Để chuyển sang **Document Q&A** đạt chất lượng demo + chi phí ≤ $90/tháng, em đề xuất 2 thay đổi lớn:

### Pivot quan trọng

| Aspect | Plan ban đầu (CPU/ARM) | **Plan thực tế (rev 2 — x86 + GPU)** |
|---|---|---|
| Head arch | ARM Graviton (`t4g.large`) | **x86 (`m6i.large`)** — share image với GPU worker |
| LLM compute | m7g.xlarge Graviton3 CPU (4 vCPU) | **g5.xlarge / g6.xlarge spot** (A10G 24GB hoặc L4 24GB) |
| Inference stack | llama.cpp Q4_K_M GGUF | **vLLM (official `vllm/vllm-openai` image) + AWQ 4-bit** |
| LLM serving model | Ray actor wrap engine | **vllm-openai HTTP server riêng**, FastAPI proxy gọi nội bộ |
| Model | Qwen3-0.6B (yếu cho RAG) | **Qwen2.5-7B-Instruct-AWQ** (MVP) |
| Vector DB node | dedicated `r7g.large` | **collocate trên head x86** (Qdrant <500 MiB RAM cho MVP) |
| Cluster lifecycle | 24/7 ($376/tháng) | **destroy/recreate, 60–80h active/tháng** |
| EKS billing | always-on $73 | prorated, ~$8/tháng |
| QA p95 latency | 27–40s (prefill bottleneck) | **~7–12s** (GPU prefill 10–20x nhanh hơn) |
| Total cost | $376 on-demand / $176 với spot | **~$50/tháng** (g5.xlarge 80h, head collocate) |

### Quyết định kiến trúc chính

1. **Cluster arch homogeneous x86**: Ray head + GPU worker đều x86. KubeRay share một image `linux/amd64` CUDA cho cả head/worker; ARM Graviton bị loại do CUDA wheel không có ARM build và Ray image arch phải đồng nhất.
2. **LLM serving:** **vllm-openai HTTP server** (official image `vllm/vllm-openai`) chạy như StatefulSet trên GPU node, expose `/v1/chat/completions`. FastAPI/Ray Serve `QAHandler` gọi qua HTTP nội bộ. Lý do tách: vLLM engine có lifecycle riêng (model load 15s, CUDA graph 8s), nếu wrap trong Ray actor thì mỗi lần Ray restart actor là reload model — dễ debug khi tách hẳn.
3. **Model + GPU**: `Qwen/Qwen2.5-7B-Instruct-AWQ` trên `g5.xlarge` (A10G 24GB, $0.40/h spot) hoặc `g6.xlarge` (L4 24GB, $0.32/h spot). Cả 2 đủ VRAM cho 7B AWQ + KV `max_model_len=8192` + 8–16 concurrent. `g4dn` (T4 16GB) chỉ fallback.
4. **Embedding:** `intfloat/multilingual-e5-small` ONNX INT8 — **CPU**, pinned trên head x86 (dư 2 vCPU).
5. **Vector DB:** Qdrant 1.11+ **collocate trên head x86** (MVP 50 docs ~ vài nghìn vectors, RAM cần < 500 MiB). PVC EBS `Retain` để data sống qua destroy. Tách dedicated node khi > 100K vectors.
6. **Ingestion:** async qua Ray Task, idempotent theo SHA-256, raw file vào S3. **Caveat:** Ray Task không durable — nếu destroy cluster giữa ingest thì job mất. MVP OK; production cần SQS/DynamoDB job table.
7. **Terraform split: `persistent/` (VPC, S3, ECR, IAM, EBS volumes) + `ephemeral/` (EKS, node groups, app)** — destroy thoải mái phần `ephemeral`, data + image vẫn còn nguyên.
8. **Context budget:** `max_model_len=8192` cho vLLM — fit top-5 chunks × 500 tok + question + 400 token answer + buffer.
9. **Quality lever ưu tiên**: nếu RAG recall kém, **upgrade retrieval trước LLM** — thêm reranker (`bge-reranker-v2-m3`) hoặc đổi embedding (`bge-m3`). Chỉ nhảy LLM 14B sau khi 7B pass eval set và retrieval đã chín.

### Phạm vi mục tiêu

- **Quality:** Recall@5 ≥ 0.80 trên VN eval set 50 câu; faithfulness ≥ 0.70.
- **Latency:** /qa p95 < 12s với top_k=5, n_ctx=8192.
- **Cost:** ≤ $90/tháng với 80h active.
- **Data seed demo:** 50 docs (Wikipedia VN + tài liệu Aposa) + eval set 50 câu hỏi VN.

---

## 1. Hiện trạng (inventory)

Nguồn: `infra/environments/dev/terraform.tfvars`, `infra/modules/kuberay/locals.tf`, `app/backends/llamacpp_backend.py`.

### 1.1 EKS topology (snapshot — đang dùng cho `llm-chat`)

| Thành phần | Spec | $/tháng us-west-2 | Vai trò |
|---|---|---:|---|
| EKS control plane | v1.30 | $73 | managed |
| Head MNG | 1× **t4g.large** (Graviton2, 2 vCPU, 8 GiB) | $48 | Ray GCS, Serve HTTP proxy, dashboard. Pod request 1/2 CPU + 2-3Gi RAM. |
| Worker MNG | 1–3× **m7g.xlarge** (Graviton3, 4 vCPU, 16 GiB) | $117–$351 | Ray worker pods chạy ChatModel. Pod request 3 CPU + 4Gi RAM, limit 3.5 CPU + 6Gi. |
| EBS gp3 | ~30 GiB | $3 | root + emptyDir overhead |
| NAT gateway | single-AZ | $33 | egress (HF model download, container pull) |
| Observability | kube-prometheus-stack + Grafana | ~$0 (in-cluster) | scrape Ray + node-exporter |
| **Total floor** | (1 worker) | **~$274** | budget violation đã có, đang chấp nhận khi demo |

> **Rev 2 note:** topology trên đang **chat-only** (ARM Graviton). Khi chuyển sang RAG GPU, **toàn bộ ARM bị bỏ** vì Ray head + GPU worker phải share image arch (CUDA wheel chỉ có `linux/amd64`). Topology mới ở §4.1.

> **Lưu ý NAT cost:** $33/tháng là cost lớn thứ 2 sau EKS control plane. Tăng RAG thêm Qdrant + Embedder tải về model lúc cold start sẽ làm NAT cost tăng nhẹ; dùng VPC endpoint cho S3/ECR đã giảm đáng kể.

### 1.2 Ray Serve config (ChatModel)

```yaml
deployments:
  - name: ChatModel
    max_ongoing_requests: 1          # CPU LLM, không batch
    autoscaling_config:
      min_replicas: 2
      max_replicas: 4
      target_ongoing_requests: 1
      upscale_delay_s: 10
      downscale_delay_s: 120
    ray_actor_options:
      num_cpus: 1.5
```

Mapping actor → pod: `actors_per_pod = 2` → tối thiểu 1 worker pod, tối đa 2 pods (4 actors / 2).

### 1.3 llama.cpp tuning hiện tại

| Param | Value | Nguồn |
|---|---|---|
| Backend | `llama-cpp-python 0.3.23` | `requirements.txt` |
| Model | Qwen3-0.6B Q4_K_M GGUF (`bartowski/Qwen_Qwen3-0.6B-GGUF`) | `Dockerfile` ARG |
| `n_ctx` | 2048 | `LLAMA_N_CTX` env |
| `n_batch` | 128 | `LLAMA_N_BATCH` env |
| `n_threads` | `ceil(replica_cpus)` = 2 | `LLAMA_N_THREADS` env |
| `max_new_tokens` server cap | 160 | `MAX_NEW_TOKENS` env |
| `max_input_tokens` | 2048 | `MAX_INPUT_TOKENS` env |
| Thinking mode | off (`/no_think` prefill) | `ENABLE_THINKING=false` |
| Cache type K/V | default FP16 | chưa quantize KV |

ARM-specific: llama-cpp-python build-from-source trên ARM64 (manylinux wheel có conflict với `compiler_compat` shim của conda base image — đã fix trong Dockerfile bằng `unset CC CXX` + `apt install build-essential cmake`).

### 1.4 Bottleneck cần chú ý cho RAG (lý do pivot sang GPU)

1. **Prompt size scale 5–10x** sau RAG (context chunks), khả năng đụng `n_ctx=2048` → phải nâng `max_model_len` lên 8192.
2. **Prefill speed trên Graviton3 m7g.xlarge** với Q4_K_M 0.6B: thực nghiệm ~80–130 tok/s. Với prompt RAG 3.3K token → **27 s chỉ prefill** — fatal cho UX.
3. **Decode speed:** Q4_K_M 0.6B trên Graviton3, 2 thread: ~25–40 tok/s.
4. **Memory ceiling:** pod limit 6 GiB. Model ~400 MB + KV (n_ctx=4096, FP16) ~250 MB + Python/Ray overhead ~1.5 GiB → packing chật.
5. **emptyDir HF cache:** mỗi pod restart tải lại GGUF qua NAT.
6. **Quality trần:** Qwen3-0.6B yếu cho RAG instruction-following (hay nhảy chủ đề, ignore context).

→ **Kết luận:** CPU stack chỉ phù hợp chat ngắn. Để làm RAG nghiêm túc, **đổi sang GPU + 7B AWQ** là quyết định kinh tế (xem §3.5.1 và §4 cost analysis).

---

## 2. Architecture target

```
                       ┌──────────────────────────────┐
                       │     User / Browser           │
                       └────────┬─────────────┬───────┘
                                │             │
                  POST /documents       POST /qa
                                │             │
                                ▼             ▼
        ┌──────────────────────────────────────────────────────┐
        │ Ray Serve application: doc-qa (in ephemeral cluster) │
        │                                                      │
        │  ┌────────────┐  ┌──────────────┐                    │
        │  │  Ingest    │  │   QA         │                    │
        │  │  handler   │  │   handler    │                    │
        │  └─────┬──────┘  └──┬───────────┘                    │
        │        │            │                                │
        │        ▼            ▼                                │
        │  ┌─────────────────────────────┐                     │
        │  │  Embedder (CPU)             │                     │
        │  │  e5-small ONNX INT8         │                     │
        │  │  pinned on head m6i.large   │                     │
        │  │  min=1 max=2                │                     │
        │  └──────────────┬──────────────┘                     │
        │                 │                                    │
        │                 ▼                                    │
        │      ┌───────────────────────────┐                   │
        │      │  Qdrant client (gRPC)     │                   │
        │      └──────────┬────────────────┘                   │
        │                 │ upsert / search                    │
        │                 ▼                                    │
        │     ┌─────────────────────────────────────────┐      │
        │     │  Qdrant StatefulSet                     │      │
        │     │  collocate on head m6i.large (MVP)      │      │
        │     │  collection: documents                  │      │
        │     │  PVC: EBS gp3 10 GiB (Retain)           │      │
        │     └─────────────────────────────────────────┘      │
        │                 │                                    │
        │                 └──── top-k chunks ─┐                │
        │                 ┌───────────────────┘                │
        │                 ▼                                    │
        │      ┌────────────────────────────────────────┐     │
        │      │  QA handler (FastAPI / Ray Serve)      │     │
        │      │  HTTP → vllm-openai server (internal)  │     │
        │      └──────────────┬─────────────────────────┘     │
        │                     │ POST /v1/chat/completions     │
        │                     ▼                               │
        │      ┌────────────────────────────────────────┐     │
        │      │  vllm-openai (GPU server)              │     │
        │      │  Qwen2.5-7B-Instruct-AWQ (4-bit)       │     │
        │      │  g5.xlarge or g6.xlarge spot           │     │
        │      │  max_model_len=8192, FP8 KV cache      │     │
        │      └────────────────────────────────────────┘     │
        └──────────────────────────────────────────────────────┘
                                │
                                ▼
                       answer + sources[]

   ═══════════════════════════════════════════════════════════
   PERSISTENT (always-on, $5–10/tháng)
   ═══════════════════════════════════════════════════════════
       VPC + subnets + IGW       S3 bucket: llm-chat-data
       (no NAT in dev)             ├─ docs/{doc_id}.pdf
       IAM + OIDC provider          ├─ snapshots/qdrant/...
       ECR repo: llm-chat-app       └─ terraform-state/
       EBS volume vol-XXXX (Qdrant data, 10GiB, gp3, Retain)
       EBS volume vol-YYYY (LLM cache, 20GiB, gp3, Retain) [optional]

   ═══════════════════════════════════════════════════════════
   EPHEMERAL (destroy/recreate, 60–80h active/tháng)
   ═══════════════════════════════════════════════════════════
       EKS cluster + 2 node groups:
         - head x86 (m6i.large)  ← Ray head + Embedder + Qdrant
         - gpu (g5.xlarge / g6.xlarge spot)  ← vllm-openai
       KubeRay operator + RayService
       NVIDIA k8s device plugin (DaemonSet)
       AWS EBS CSI driver (cho PVC Retain)
       kube-prometheus-stack + Grafana + DCGM exporter
       App pods (FastAPI/Ray Serve + Embedder + Qdrant + vllm-openai)
```

### Cluster lifecycle

```
                Setup once
                    │
                    ▼
           [persistent/ stack]
           terraform apply
           VPC, S3, ECR, EBS, IAM
                    │
        ┌───────────┴───────────┐
        │                       │
        ▼                       ▼
  [Demo / Dev session]     [Idle]
  cluster-up.sh (15 min)   nothing running on EC2
  ephemeral/ apply         EBS data preserved
  Image pull from ECR      EKS not billed
  PV bind → Qdrant ready   ECR + S3 + EBS billed (~$3/mo)
        │
        ▼
  Run demo / develop
        │
        ▼
  cluster-down.sh (5 min)
  Snapshot Qdrant → S3
  ephemeral/ destroy
        │
        └─────────► back to [Idle]
```

### 2.1 Routing

| Method | Path | Backend deployment | SLA target p95 |
|---|---|---:|---|
| POST | `/documents` | Ingest handler (lightweight) → Ray Task | < 500 ms (sync ack) |
| GET | `/documents` | Ingest handler | < 200 ms |
| GET | `/documents/{doc_id}` | Ingest handler | < 200 ms |
| DELETE | `/documents/{doc_id}` | Ingest handler | < 500 ms |
| POST | `/qa` | QA handler → Embedder + Qdrant + ChatModel | **< 8 s** (p95, top_k=5) |
| POST | `/chat` | ChatModel | < 4 s |
| GET | `/healthz` | Ingest handler (check Qdrant + Embedder) | < 100 ms |

---

## 3. Component design

### 3.1 Embedding service

#### 3.1.1 Model selection

Trade-off matrix, đánh giá trên Graviton3 (m7g.xlarge, 2 threads):

| Model | Size disk | Dim | Throughput batch=32 | Recall@5 (CTRL test set) | VN support | Quyết định |
|---|---:|---:|---:|---:|:---:|---|
| `intfloat/multilingual-e5-small` | 471 MB FP32 / 118 MB INT8 | 384 | ~60–80 sent/s INT8 | 0.82 | ✅ tốt | **Chọn** |
| `BAAI/bge-small-en-v1.5` | 133 MB FP32 / 33 MB INT8 | 384 | ~100–120 sent/s INT8 | 0.85 (EN) | ❌ kém | EN-only |
| `paraphrase-multilingual-MiniLM-L12-v2` | 471 MB / 118 MB INT8 | 384 | ~60 sent/s | 0.74 | ✅ | dropout — recall thấp |
| `BAAI/bge-m3` | 2.3 GB FP32 | 1024 | ~15 sent/s | 0.91 | ✅ rất tốt | **Phase 2** khi có budget |
| `Alibaba-NLP/gte-multilingual-base` | 305 MB / 76 MB INT8 | 768 | ~40 sent/s INT8 | 0.88 | ✅ tốt | Phase 2 candidate |

> **Số throughput là ước lượng**, phải bench thực tế trong Phase 0 (`scripts/bench_embedder.py`).
> **Recall@5** là dummy — phải build CTRL test set với 100 cặp (query, relevant_doc) tiếng Việt sau Phase 4.

**Lý do chọn e5-small:**
- INT8 quantize (ONNX dynamic quantization) giảm size disk 4x và inference time ~1.5–2x, vẫn giữ recall trong vòng -1% so với FP32.
- Multilingual coverage cho VN tốt hơn rõ rệt so với MiniLM.
- 384 dim = vector DB nhỏ gọn (xem §3.2).

**Yêu cầu prefix:** e5 model yêu cầu prefix `query: ` cho query và `passage: ` cho chunk lúc embed → **phải code đúng**, sai prefix sẽ giảm recall 10–15%.

```python
# ingest path
texts = [f"passage: {chunk.text}" for chunk in chunks]
# query path
query_embed = model.encode(f"query: {question}")
```

#### 3.1.2 Runtime: ONNX Runtime vs PyTorch vs llama.cpp

| Runtime | ARM-NEON | INT8 | Setup | Speed (ước lượng) |
|---|:---:|:---:|---|---:|
| `sentence-transformers` (PyTorch CPU) | ✅ qua aten | dynamic INT8 yếu | dễ | baseline |
| **ONNX Runtime + onnxruntime-arm64** | ✅ native | ✅ tốt (dynamic + static) | optimum-cli export | **+50–80%** |
| llama.cpp (BERT GGUF) | ✅ NEON tốt | Q4_0/Q8_0 | phải convert GGUF, sentence-transformers chưa export sẵn | tương đương ONNX |
| AWS ACL backend cho ORT | ✅ Graviton-optimized | ✅ | đặc biệt build wheel | +10–20% so với ORT default |

**Quyết định:** ONNX Runtime default build trên ARM64 wheel (`onnxruntime==1.20.0+`). Skip ACL build vì phức tạp; chỉ cân nhắc nếu Phase 0 bench cho thấy throughput < 30 sent/s.

Export model:
```bash
optimum-cli export onnx \
  --model intfloat/multilingual-e5-small \
  --task feature-extraction \
  --device cpu \
  --optimize O2 \
  ./embedder-onnx

# INT8 quantize
optimum-cli onnxruntime quantize \
  --onnx_model ./embedder-onnx \
  --output ./embedder-onnx-int8 \
  --avx2 false --arm64 true \
  --per_channel
```

Resulting artifacts → vào layer Docker (preload), không tải lúc runtime.

#### 3.1.3 Ray Serve deployment

```python
@serve.deployment(
    name="Embedder",
    num_replicas=1,
    max_ongoing_requests=8,        # batch-friendly
    autoscaling_config={
        "min_replicas": 1,
        "max_replicas": 3,
        "target_ongoing_requests": 4,
        "upscale_delay_s": 5,
        "downscale_delay_s": 60,
    },
    ray_actor_options={
        "num_cpus": 1.0,
    },
)
class Embedder:
    def __init__(self):
        import onnxruntime as ort
        from tokenizers import Tokenizer
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 1     # giữ 1 thread/replica, để chỗ cho Qdrant + Ray head trên cùng node
        opts.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        self.sess = ort.InferenceSession(MODEL_PATH, opts, providers=["CPUExecutionProvider"])
        self.tokenizer = Tokenizer.from_file(TOKENIZER_PATH)

    async def __call__(self, texts: list[str]) -> list[list[float]]:
        # batch by default — list[str] in, list[vec] out
        ...
```

> **Packing trên head m6i.large (2 vCPU, 8 GiB)** — MVP:
> - Ray head: 0.5 CPU / 1.5 GiB
> - Embedder (1 replica): 1.0 CPU / 1 GiB
> - Qdrant (collocate, MVP scale): 0.3 CPU / 1 GiB
> - **Tổng: ~1.8 CPU / 3.5 GiB** trên 2 vCPU / 8 GiB — vừa khít, dư RAM.
> - Khi ingest traffic tăng → upgrade head lên `m6i.xlarge` (4 vCPU / 16 GiB, +$70/mo) **hoặc** tách Qdrant ra node riêng (xem §3.2.3).
> - GPU node (`g5.xlarge`) **không host bất kỳ thứ gì ngoài vllm-openai pod** — không pack Embedder/Qdrant lên đó để tránh tranh CPU với vLLM scheduler.

### 3.2 Vector database — Qdrant

#### 3.2.1 Lý do chọn Qdrant (so với pgvector, Milvus, Chroma, Weaviate)

| Tiêu chí | Qdrant | pgvector | Milvus | Chroma | Weaviate |
|---|:---:|:---:|:---:|:---:|:---:|
| ARM64 official image | ✅ | ✅ (PG image) | ⚠️ phải tự build | ✅ | ✅ |
| Memory footprint nhỏ | ✅ (<1GB cho 100K vectors) | ⚠️ tốn PG overhead | ❌ cần 4-8 GB min | ✅ | ⚠️ |
| Disk-based với memmap | ✅ (`memmap_threshold`) | ❌ | ✅ | ⚠️ partial | ⚠️ |
| Payload filtering | ✅ rất linh hoạt | ✅ SQL | ✅ | ⚠️ | ✅ |
| gRPC | ✅ (perf tốt hơn HTTP ~30%) | ❌ | ✅ | ❌ | ⚠️ |
| Deploy K8s đơn giản | ✅ 1 StatefulSet | ✅ qua operator | ❌ Helm + 4-5 deployment | ✅ | ⚠️ |
| Rust binary (low overhead) | ✅ | — | C++ | Python | Go |

→ **Qdrant** thắng trên ARM + lightweight + deploy đơn giản.

#### 3.2.2 Sizing math

Công thức storage cho HNSW collection:
```
storage_per_point = vector_dim × 4 bytes + payload_size + hnsw_overhead

hnsw_overhead ≈ M × 8 bytes + index_levels × 8 bytes
M = 16 (default) → ~150 bytes overhead/point
```

Với e5-small (384 dim) + payload trung bình 1.2 KB (text chunk 500 token + metadata):

| Scale | # vectors | Raw vectors | Payload | HNSW | **Total disk** | **RAM (mmap)** | PVC khuyến nghị |
|---|---:|---:|---:|---:|---:|---:|---:|
| MVP (50 docs × 50 chunks) | 2,500 | 3.7 MB | 3 MB | 0.4 MB | **~10 MB** | ~10 MB | 1 GiB |
| Small (1K docs) | 50,000 | 75 MB | 60 MB | 7.5 MB | **~150 MB** | ~150 MB | 5 GiB |
| Mid (10K docs) | 500,000 | 750 MB | 600 MB | 75 MB | **~1.5 GB** | ~750 MB (vector only, payload on-disk) | 20 GiB |
| Large (100K docs) | 5,000,000 | 7.5 GB | 6 GB | 750 MB | **~15 GB** | ~3 GB (với memmap_threshold) | 50 GiB |

**Memory-saving config:**
```yaml
# Qdrant storage settings (collection-level)
optimizers_config:
  memmap_threshold: 20000        # > 20K vectors → memmap thay vì RAM
  indexing_threshold: 10000      # build HNSW khi >10K vectors

hnsw_config:
  m: 16
  ef_construct: 128              # quality vs build speed
  on_disk: true                  # HNSW index trên disk (chậm hơn ~20% nhưng RAM thấp)
```

#### 3.2.3 Deploy spec — collocate trên head node (MVP)

```yaml
# k8s/qdrant.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: qdrant
  namespace: llm-chat
spec:
  serviceName: qdrant
  replicas: 1                    # MVP single-node; cluster mode = phase 2
  selector: {matchLabels: {app: qdrant}}
  template:
    metadata:
      labels: {app: qdrant}
    spec:
      nodeSelector:
        "node-type": "head"          # collocate trên head m6i.large
      tolerations:
        - key: "ray-role"            # head có taint cho Ray
          operator: "Equal"
          value: "head"
          effect: "NoSchedule"
      containers:
        - name: qdrant
          image: qdrant/qdrant:v1.11.3       # multi-arch (amd64 cho m6i)
          ports:
            - {containerPort: 6333, name: http}
            - {containerPort: 6334, name: grpc}
          env:
            - {name: QDRANT__LOG_LEVEL, value: INFO}
            - {name: QDRANT__SERVICE__GRPC_PORT, value: "6334"}
            - {name: QDRANT__STORAGE__OPTIMIZERS__DEFAULT_SEGMENT_NUMBER, value: "2"}
          resources:
            requests: {cpu: "300m", memory: "512Mi"}   # MVP scale
            limits:   {cpu: "1",    memory: "2Gi"}
          volumeMounts:
            - {name: data, mountPath: /qdrant/storage}
          readinessProbe:
            httpGet: {path: /readyz, port: 6333}
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            httpGet: {path: /livez, port: 6333}
            initialDelaySeconds: 30
            periodSeconds: 30
  # KHÔNG dùng volumeClaimTemplates ở đây — bind PV pre-created từ persistent EBS
  # (PVC kèm storageClassName: gp3-retain, claim PV qdrant-data-pv → vol-XXXX)
```

> **Rev 2:** bỏ dedicated `vector-db` node group (`r7g.large`). Lý do:
> - MVP 50 docs × 50 chunks = 2,500 vectors × 384 dim × 4B + payload + HNSW ≈ **10 MiB total** (xem §3.2.2).
> - Qdrant idle RAM ~ 200 MiB, peak ~ 500 MiB cho scale này.
> - `m6i.large` head có 8 GiB RAM — thừa thãi.
> - **Tách lại node riêng khi:**
>   - Vectors > 100K (RAM Qdrant cần > 2 GiB) **hoặc**
>   - Embedder/Qdrant tranh CPU và `qdrant_search_latency_p95 > 100ms` **hoặc**
>   - Cluster scale lên multi-Qdrant cho HA.

#### 3.2.4 Collection schema

```python
client.create_collection(
    collection_name="documents",
    vectors_config=VectorParams(
        size=384,
        distance=Distance.COSINE,
        on_disk=False,                  # vector in RAM for low-latency search
    ),
    hnsw_config=HnswConfigDiff(m=16, ef_construct=128, on_disk=True),
    optimizers_config=OptimizersConfigDiff(
        memmap_threshold=20_000,
        indexing_threshold=10_000,
        default_segment_number=2,       # match num_cpus
    ),
    payload_index=[
        ("doc_id", PayloadSchemaType.KEYWORD),     # filter theo doc_id
        ("status", PayloadSchemaType.KEYWORD),     # filter theo soft-deleted
    ],
)
```

Payload mỗi point:
```json
{
  "doc_id": "<sha256-prefix>",
  "doc_title": "string",
  "chunk_idx": 12,
  "page": 4,
  "text": "<original chunk text>",
  "char_count": 1842,
  "ingested_at": "2026-05-18T02:17:15Z",
  "status": "active"
}
```

### 3.3 Ingestion pipeline

> **Durability caveat (rev 2):** ingest job dùng Ray Task — **không durable**. Nếu cluster destroy (hoặc Ray head pod crash) giữa lúc ingest, job mất, doc kẹt ở `status=processing` mãi.
>
> - **MVP OK**: doc ingest mất < 60s; user re-upload là re-trigger từ đầu vì `doc_id` (SHA-256) trùng → idempotent.
> - **Production cần**: SQS queue + worker pool consume + DynamoDB job table, hoặc dùng Ray Workflows (durable). Out of scope cho MVP. Plan riêng nếu scale > 100 docs/ngày.
> - **Workaround MVP**: cron job mỗi 10 min scan S3 meta cho `status=processing` quá 5 min → mark `failed` (cleanup partial Qdrant chunks bằng filter `doc_id`).

#### 3.3.1 Flow

```
POST /documents (multipart, max 50 MiB)
  ↓
[1] Validate
    - size ≤ 50 MiB → else 413
    - mime in {pdf, txt, md, docx} → else 415
[2] Compute doc_id = sha256(file_bytes)[:16]
[3] Check existence: HEAD s3://bucket/docs/{doc_id}.*
    - exists → return {doc_id, status: "exists", chunks: N} (200)
[4] Upload raw to S3 (PutObject, SSE-S3)
[5] Write meta: s3://bucket/meta/{doc_id}.json {status: "processing", uploaded_at}
[6] Submit Ray Task: ingest_task.remote(doc_id)
[7] Return 202 Accepted {doc_id, status: "processing"}

ingest_task (async, on worker pod):
[a] Download from S3 → /tmp/{doc_id}.{ext}
[b] Parse:
    - pdf:  pypdf (text-only); detect scan PDF → fail "no_text_layer"
    - docx: python-docx
    - md/txt: read directly
[c] Chunk: RecursiveCharacterTextSplitter (size=500 token, overlap=80, by tiktoken cl100k_base)
[d] For each batch of 32 chunks:
    - Call Embedder.remote(texts=[f"passage: {c}" for c in batch])
    - Upsert to Qdrant (gRPC client, async)
[e] Update meta: {status: "ready", num_chunks: N, completed_at}

On failure (any step):
- Update meta: {status: "failed", error_code: "...", error_msg: "..."}
- Log to CloudWatch + Prometheus counter ingest_failures_total{reason}
- Do NOT delete raw file (allow inspection)
```

#### 3.3.2 Chunking strategy detailed

```python
from langchain_text_splitters import RecursiveCharacterTextSplitter
import tiktoken

enc = tiktoken.get_encoding("cl100k_base")

def token_len(s: str) -> int:
    return len(enc.encode(s))

splitter = RecursiveCharacterTextSplitter(
    chunk_size=500,
    chunk_overlap=80,
    length_function=token_len,
    separators=[
        "\n\n## ",  "\n\n# ",       # markdown headings — ưu tiên cao
        "\n\n",                       # paragraph
        "\n",                         # line
        ". ", "? ", "! ",             # sentence
        "; ", ", ",                   # clause
        " ", "",
    ],
)
```

**Trade-off chunk_size:**

| chunk_size | Recall@5 | Context tokens | Phù hợp |
|---:|---:|---:|---|
| 200 | ~0.78 | 1000 (top-5) | Lookup ngắn, fact-based QA |
| **500** | **~0.85** | **2500** | **MVP default** |
| 800 | ~0.86 | 4000 | Tài liệu hành chính dài, ít fragmentation |
| 1500 | ~0.83 | 7500 | Bắt buộc n_ctx ≥ 8192 |

→ Bắt đầu 500, đo recall qua eval set, điều chỉnh.

#### 3.3.3 Idempotency + edge cases

| Edge case | Cách xử lý |
|---|---|
| Re-upload cùng file (same SHA-256) | Step [3] return early `exists` — không re-parse |
| Upload version mới (đổi nội dung) | doc_id khác, file mới được ingest. UI phải hiển thị 2 entry. Soft-delete cái cũ qua `DELETE /documents/{old_id}`. |
| Race: 2 upload đồng thời cùng file | Ray Task có cùng key (doc_id) → dùng Ray "named actor" hoặc S3 conditional put (`If-None-Match: *`) làm lock. |
| PDF scan-only (image PDF) | Phát hiện `total_text < 100 chars` → fail status `pdf_no_text_layer` với hint "cần OCR" |
| File parse được nhưng 0 chunk hữu ích | Status `empty_document` |
| File quá lớn (>50 MB) | Reject 413 ở step [1] |
| Encoding latin-1 / cp1252 | Detect bằng `chardet` (confidence > 0.7), normalize UTF-8 |
| Tài liệu tiếng Việt có dấu | E5 multilingual đã train trên VN — test với eval set 50 câu VN |
| OOM khi parse PDF 500+ trang | pypdf streaming page-by-page, không load all in memory |
| Ingest crash giữa chừng | Status `failed` trong meta; user re-upload sẽ trigger lại từ [4] (vì step [3] check existence dựa trên S3 file, nhưng Qdrant point có thể partial → cần cleanup). Khuyến nghị: trước [d], `client.delete(filter=doc_id==X)` để xoá partial. |

### 3.4 Retrieval + RAG generation

#### 3.4.1 QA flow

```
POST /qa {question, doc_ids?: [...], top_k?: 5, score_threshold?: 0.5}
  ↓
[1] Validate question len ≤ 500 tokens (else 400)
[2] embed = Embedder.remote([f"query: {question}"])
[3] hits = qdrant.search(
        collection="documents",
        query_vector=embed[0],
        limit=top_k,
        score_threshold=0.5,
        query_filter=Filter(must=[
            FieldCondition(key="status", match=MatchValue(value="active")),
            *([FieldCondition(key="doc_id", match=MatchAny(any=doc_ids))] if doc_ids else []),
        ]),
    )
[4] If not hits: return {answer: "Tôi không tìm thấy thông tin liên quan trong tài liệu.", sources: []}
[5] context = "\n\n".join(
        f"[Nguồn {i+1}: {h.payload['doc_title']}, đoạn {h.payload['chunk_idx']}]\n{h.payload['text']}"
        for i, h in enumerate(hits)
    )
[6] prompt = RAG_PROMPT_TEMPLATE.format(context=context, question=question)
[7] answer = await ChatModel.__call__.remote(messages=[
        {"role": "system", "content": RAG_SYSTEM},
        {"role": "user", "content": prompt},
    ], max_new_tokens=400, temperature=0.2)
[8] return {answer, sources: [{doc_id, doc_title, chunk_idx, score, text}], latency_ms: {...}}
```

#### 3.4.2 Prompt template

```python
RAG_SYSTEM = """Bạn là trợ lý trả lời câu hỏi dựa trên các đoạn tài liệu cho trước.
Quy tắc bắt buộc:
1. CHỈ trả lời dựa trên nội dung trong CONTEXT phía dưới.
2. Nếu CONTEXT không đủ thông tin để trả lời chính xác, trả lời CHÍNH XÁC chuỗi: "Tôi không tìm thấy thông tin trong tài liệu."
3. Sau mỗi khẳng định, thêm tham chiếu dạng [Nguồn N] tương ứng với đoạn nguồn.
4. Trả lời ngắn gọn, không bịa số liệu, không suy diễn.
5. Trả lời bằng cùng ngôn ngữ với câu hỏi."""

RAG_PROMPT_TEMPLATE = """CONTEXT:
{context}

CÂU HỎI: {question}

TRẢ LỜI:"""
```

#### 3.4.3 Token budget cho `n_ctx=4096`

| Thành phần | Tokens (worst-case) |
|---|---:|
| System prompt (RAG_SYSTEM) | ~180 |
| Per-chunk header `[Nguồn N: ...]` × 5 | 5 × 25 = 125 |
| Chunk content × 5 (500 token each) | 2,500 |
| Câu hỏi user (cap ở 500) | 500 |
| Template scaffolding | ~30 |
| **Total prefill** | **~3,335** |
| Generation room | 4,096 - 3,335 = **761** |

→ `max_new_tokens=400` an toàn, còn buffer ~360 token. Nếu user gửi câu hỏi 700 token sẽ vượt; cap ở 500.

**Nâng `n_ctx` lên 8192** (phase 2): cho phép top_k=10 hoặc chunk lớn 800 tok. KV cache cost xem §4.

#### 3.4.4 Edge cases QA

| Case | Xử lý |
|---|---|
| Top hit score < `score_threshold` (0.5) | Skip LLM, return "không có" — tiết kiệm 5–8s |
| Question quá ngắn (≤ 3 ký tự) | 400 `question_too_short` |
| Tất cả top-k cùng 1 doc (low diversity) | Pre-rank bằng MMR (`lambda=0.5`) — Phase 2 |
| LLM trả "không biết" mặc dù có context | Log `qa.fallback_despite_context` để phân tích chunking |
| LLM bịa số liệu | Soft-constraint qua prompt; hard check (regex extract dates/numbers, verify trong context) — Phase 2 |
| Câu hỏi multi-hop (cần tổng hợp 2+ doc) | RAG yếu — out of scope MVP, plan riêng cho map-reduce |
| Streaming response | Ray Serve hỗ trợ `StreamingResponse`; phase 2 cho UX tốt hơn |
| Qdrant down | QA handler return 503 — KHÔNG fallback no-context (sai sự thật nguy hiểm hơn timeout) |
| Embedder down | Tương tự, 503 |
| ChatModel down | 503; circuit breaker với Ray Serve handle exception |

### 3.5 LLM tuning cho RAG — GPU + vLLM

#### 3.5.1 Vì sao đổi từ llama.cpp CPU → vLLM GPU

RAG prompt rất dài (3K+ token prefill). Bottleneck thực tế trên CPU Graviton3:
- Prefill 3,300 token × 1/120 tok/s = **27 s** chỉ để chuẩn bị KV cache.
- Decode 400 token × 1/30 tok/s = **13 s**.
- Total ~40 s/request — **không acceptable** cho demo Q&A.

GPU đánh thẳng vào prefill (kernel matmul song song):
- A10G prefill Qwen2.5-7B AWQ: **~2,000 tok/s** (16x faster).
- A10G decode: ~80 tok/s.
- Total ~7s — **đạt SLA <12s** với headroom.

Bonus: chạy được model 7B–14B class (instead of 0.6B) → quality nhảy 1 đẳng cấp cho RAG.

#### 3.5.2 Model lựa chọn

| Model | Quantization | VRAM (model+8K KV) | Decode tok/s A10G | Quality VN RAG | Phù hợp |
|---|---|---:|---:|---|---|
| Qwen2.5-7B-Instruct-AWQ | AWQ 4-bit | ~5 GB | 70–90 | rất tốt | **MVP** |
| Qwen2.5-14B-Instruct-AWQ | AWQ 4-bit | ~9 GB | 40–55 | xuất sắc | **chỉ upgrade sau khi retrieval chín** |
| Qwen2.5-7B-Instruct GPTQ | GPTQ 4-bit | ~5 GB | 65–85 | rất tốt | alternative |
| Qwen2.5-7B-Instruct FP16 | none | ~14 GB | 50 | rất tốt | không cần thiết, tốn VRAM |
| Llama-3.1-8B-Instruct-AWQ | AWQ 4-bit | ~6 GB | 60–80 | tốt, EN mạnh hơn VN | candidate |

**Quyết định:** `Qwen/Qwen2.5-7B-Instruct-AWQ` cho MVP.

> **Thứ tự upgrade quality** (review feedback):
> 1. **Trước tiên — retrieval**: bench recall@5 với eval set VN. Nếu < 0.75 → thêm reranker (`BAAI/bge-reranker-v2-m3` chạy CPU) hoặc đổi embedding lên `bge-m3` (multilingual, 1024 dim). Retrieval xấu thì LLM mạnh đến mấy cũng bịa.
> 2. **Sau đó — chunking**: đo recall vs `chunk_size ∈ {300, 500, 800}` và overlap.
> 3. **Cuối cùng — LLM**: chỉ nhảy 14B nếu cả retrieval recall + chunk size đã pass eval, và faithfulness/quality vẫn dưới mức. 14B làm latency +50% và cold start +30s — đừng đốt budget này trước khi cần.

#### 3.5.3 KV cache math cho Qwen2.5-7B trên A10G

Qwen2.5-7B architecture:
- `num_hidden_layers = 28`
- `hidden_size = 3584`
- `num_attention_heads = 28`, `num_key_value_heads = 4` (GQA)
- `head_dim = 128`

KV cache per token (FP16):
```
kv_per_token = 2 × n_layers × n_kv_heads × head_dim × 2 bytes
             = 2 × 28      × 4           × 128      × 2
             = 57,344 bytes/token ≈ 56 KiB/token
```

| `max_model_len` | KV cache | Model (AWQ) | Total VRAM | Headroom (24GB A10G) |
|---:|---:|---:|---:|---:|
| 4096 | 234 MB | 4.5 GB | ~5.5 GB | 18.5 GB |
| **8192** | **469 MB** | **4.5 GB** | **~6 GB** | **18 GB** |
| 16384 | 938 MB | 4.5 GB | ~6.5 GB | 17.5 GB |
| 32768 | 1.83 GB | 4.5 GB | ~7.5 GB | 16.5 GB |

vLLM `gpu_memory_utilization=0.85` sẽ pre-allocate 24×0.85 = 20.4 GB cho KV cache pool — đủ cho **continuous batching** ~30 request đồng thời với prompt ~3K tokens.

#### 3.5.4 vLLM serving — chạy `vllm-openai` server riêng (rev 2)

**Pattern (rev 2):** vLLM chạy như **HTTP server độc lập** (`vllm-openai` official image) trên GPU pod. FastAPI/Ray Serve `QAHandler` gọi qua HTTP `/v1/chat/completions` nội bộ (cluster DNS).

**Lý do tách:**
- vLLM engine model load 15s + CUDA graph 8s → lifecycle độc lập, không bị ràng buộc với Ray actor restart.
- Debug dễ: `kubectl logs vllm-server-0` thấy ngay vLLM metrics + sampling stack, không bị Ray actor wrap che.
- Có sẵn metrics endpoint `/metrics` Prometheus (vLLM stats: prefill/decode tok/s, KV cache util, num_running, num_waiting).
- OpenAI-compatible API → swap sang TGI / SGLang / Triton mà QA handler không phải sửa.

```yaml
# k8s/vllm-server.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: vllm-server
  namespace: llm-chat
spec:
  serviceName: vllm-server
  replicas: 1
  selector: {matchLabels: {app: vllm-server}}
  template:
    metadata:
      labels: {app: vllm-server}
    spec:
      nodeSelector: {node-type: gpu-worker}
      tolerations:
        - {key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}
      containers:
        - name: vllm
          image: vllm/vllm-openai:latest-stable    # official, không hand-build
          args:
            - "--model=Qwen/Qwen2.5-7B-Instruct-AWQ"
            - "--quantization=awq_marlin"
            - "--max-model-len=8192"
            - "--gpu-memory-utilization=0.85"
            - "--kv-cache-dtype=fp8_e5m2"          # A10G/L4 hỗ trợ
            - "--max-num-seqs=16"
            - "--dtype=float16"
            - "--enforce-eager=false"
            - "--swap-space=4"
            - "--served-model-name=qwen-rag"
            - "--port=8000"
          ports:
            - {containerPort: 8000, name: http}
          env:
            - {name: HF_HOME, value: /models/hf-cache}
          resources:
            requests: {cpu: "3", memory: "12Gi", nvidia.com/gpu: 1}
            limits:   {cpu: "3.5", memory: "14Gi", nvidia.com/gpu: 1}
          volumeMounts:
            - {name: model-cache, mountPath: /models/hf-cache}
          readinessProbe:
            httpGet: {path: /health, port: 8000}
            initialDelaySeconds: 60     # model load 15s + CUDA graph 8s
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 12
      volumes:
        - name: model-cache
          persistentVolumeClaim:
            claimName: llm-cache-pvc    # bind EBS Retain để không re-download 5GB mỗi cluster-up
---
apiVersion: v1
kind: Service
metadata: {name: vllm-server, namespace: llm-chat}
spec:
  clusterIP: None       # headless, gọi qua DNS vllm-server-0.vllm-server
  selector: {app: vllm-server}
  ports:
    - {name: http, port: 8000, targetPort: 8000}
```

**QA handler client** (FastAPI / Ray Serve):

```python
# app/handlers/qa.py
import httpx
from openai import AsyncOpenAI

VLLM_BASE_URL = os.environ.get("VLLM_BASE_URL", "http://vllm-server-0.vllm-server.llm-chat:8000/v1")
client = AsyncOpenAI(base_url=VLLM_BASE_URL, api_key="not-needed")

async def generate_answer(messages: list[dict]) -> str:
    resp = await client.chat.completions.create(
        model="qwen-rag",
        messages=messages,
        temperature=0.2,
        top_p=0.85,
        max_tokens=400,
        stop=["<|im_end|>", "\n\nCÂU HỎI:"],
    )
    return resp.choices[0].message.content
```

> **Streaming** (Phase 2): client dùng `stream=True`, vllm-openai trả SSE; FastAPI proxy lại thành SSE cho browser.

#### 3.5.5 Generation params cho RAG (gọi qua OpenAI API)

```python
# QA handler dùng OpenAI SDK, params equivalent với vllm SamplingParams
{
    "temperature": 0.2,            # RAG cần xác định, không creative
    "top_p": 0.85,
    "max_tokens": 400,
    "frequency_penalty": 0.05,
    "stop": ["<|im_end|>", "<|endoftext|>", "\n\nCÂU HỎI:"],
}
```

#### 3.5.6 Docker images (rev 2 — official + app proxy)

**Image 1: vLLM server** — KHÔNG tự build. Dùng official:
```
docker pull vllm/vllm-openai:latest-stable   # ~7 GiB; CUDA 12.1, torch 2.x, vLLM mới nhất stable
```

Pin version cụ thể (tag immutable) khi deploy production. Lý do dùng official:
- vLLM thay đổi nhanh; tự build dễ dính `torch + flash-attn + autoawq` version mismatch.
- Official image đã test pass cho AWQ + Marlin + FP8 KV trên Ampere/Ada.
- Bao gồm sẵn `/v1/chat/completions`, `/health`, `/metrics` (Prometheus).

Pre-download model: dùng **PVC `llm-cache-pvc`** (xem §4.3 persistent EBS) — vllm-openai sẽ tải về lần đầu qua HF Hub, lần sau đọc từ EBS. KHÔNG bake model vào image (giữ image nhỏ, tránh ECR pull 12 GiB mỗi cluster-up).

**Image 2: app proxy (FastAPI + Ray Serve QA handler)** — build từ repo:
```dockerfile
# Dockerfile.app  (x86_64, vì cùng cluster với GPU node)
FROM python:3.11-slim

WORKDIR /serve
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
# requirements: fastapi, uvicorn, ray[serve]==2.55.1, openai>=1.40,
#               onnxruntime==1.20.0, tokenizers, qdrant-client, pypdf, etc.

# Pre-download embedder ONNX (~120 MiB INT8) — fast, OK to bake
RUN python -c "from optimum.exporters.onnx import main_export; \
    main_export('intfloat/multilingual-e5-small', '/models/embedder-onnx', \
                task='feature-extraction')"
# Quantize step here (~80 MiB after INT8)

COPY app ./app
COPY scripts ./scripts

ENV EMBEDDER_MODEL_PATH=/models/embedder-onnx-int8
ENV PYTHONPATH=/serve
CMD ["python", "-m", "app.server"]
```

Image size: ~1.5 GiB (no CUDA libs). ECR pull trên head: ~15s.

> **Image build pipeline:** CI/CodeBuild trên `linux/amd64` (không cross-compile từ ARM dev box). GitHub Actions runner `ubuntu-latest` đủ.

#### 3.5.7 NVIDIA device plugin

```hcl
# infra/modules/kuberay/nvidia_device_plugin.tf
resource "helm_release" "nvidia_device_plugin" {
  name             = "nvidia-device-plugin"
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = "0.14.5"
  namespace        = "kube-system"
  create_namespace = false

  set {
    name  = "tolerations[0].key"
    value = "nvidia.com/gpu"
  }
  set { name = "tolerations[0].operator", value = "Exists" }
  set { name = "tolerations[0].effect",   value = "NoSchedule" }
}
```

Verify trên node:
```bash
kubectl get node <gpu-node> -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'
# Expect: 1
```

### 3.6 Frontend choice — HTMX vs React+Vite

Hiện `app/server.py` chỉ có inline HTML chat đơn giản. RAG UI cần thêm: upload form, document list, ingest status polling, QA box, source citations expand/collapse, optional latency breakdown panel.

| Aspect | **HTMX + Alpine.js** (recommended MVP) | **React + Vite + TypeScript** |
|---|---|---|
| Stack | FastAPI render Jinja2 HTML + HTMX swap | SPA build, FastAPI = API-only |
| Setup | 0 build step; chỉ thêm template + `<script src=htmx>` | npm install, vite config, CORS setup |
| Code | ~300 LOC HTML+Jinja | ~1,000 LOC TS + components |
| Effort | 0.5 ngày | 1.5 ngày |
| Tốc độ first paint | Rất nhanh (SSR) | Cần JS bundle parse |
| Streaming response (Phase 2) | SSE qua HTMX `hx-ext=sse` — OK | EventSource native — OK |
| Maintain dài hạn | Khi UI phức tạp > 5 màn → khó | Scale tốt với component model |
| Demo "đẹp" cho stakeholder | Đủ; hơi ascetic | Polished hơn, dễ tweak CSS |

**Khuyến nghị:**
- **MVP demo:** HTMX. Lý do: lab project, demo course, 5–8 màn cơ bản, 0 build step → cluster-up + cài app + show xong trong 1 buổi.
- **Nếu sau MVP định pitch như product**, migrate sang React+Vite ở Phase 11+.

```
# HTMX UI surfaces (MVP)
GET  /             → render home (upload form + chat box + doc list partial)
POST /documents    → return doc card partial (htmx swap into list)
GET  /documents    → list partial (poll every 3s for processing → ready)
POST /qa           → return answer card partial (sources expandable)
```

---

## 4. Resource sizing — EC2 specific + lifecycle

### 4.1 Node groups (ephemeral cluster — rev 2)

| Node group | Instance | vCPU | RAM | GPU | $/h on-demand | $/h spot | Vai trò |
|---|---|---:|---:|---|---:|---:|---|
| `head` | **m6i.large** (x86) | 2 | 8 | — | $0.096 | ~$0.030 | Ray head, FastAPI proxy, **Embedder + Qdrant collocate** |
| `gpu` | **g6.xlarge** (primary) | 4 | 16 | **L4 24GB** | $0.805 | **~$0.32** | vllm-openai server |
| `gpu` | **g5.xlarge** (fallback) | 4 | 16 | **A10G 24GB** | $1.006 | ~$0.40 | vllm-openai server |
| `gpu` | g4dn.xlarge (cheap fallback) | 4 | 16 | T4 16GB | $0.526 | ~$0.21 | KV cache hạn chế, no FP8 |

**Spot diversification trong 1 MNG:** đặt `instance_types = ["g6.xlarge", "g5.xlarge", "g4dn.xlarge"]` với `spot_allocation_strategy = "capacity-optimized-prioritized"`. EKS sẽ pick GPU rẻ + còn capacity, ưu tiên theo thứ tự.

**Tại sao chọn (rev 2):**
- **m6i.large head x86:** Ray head + GPU worker phải cùng arch để share CUDA image. m6i Ice Lake giá tốt, đủ cho head + Embedder + Qdrant collocate ở MVP scale. Alternative: `t3a.large` (~$25/mo on-demand) nếu siết budget hơn.
- **g6.xlarge primary:** L4 24GB Ada arch (2023), inference-oriented, hỗ trợ FP8 KV. **Rẻ hơn g5.xlarge $0.08/h × 80h = ~$6.4/mo**. AWS định vị G6 thay G5 cho inference workload mới.
- **g5.xlarge fallback:** A10G 24GB, spot pool lớn hơn ở us-west-2, FP8 KV support. Pick khi g6 spot không có.
- **g4dn.xlarge cheap fallback only:** T4 Turing — KHÔNG hỗ trợ FP8 KV cache, decode throughput thấp hơn ~3x. 16 GB VRAM đủ 7B AWQ nhưng margin thấp; KHÔNG fit 14B AWQ.

### 4.2 Pod resource matrix (rev 2)

| Pod | Node | CPU req/limit | RAM req/limit | GPU | Replicas |
|---|---|---|---|---:|---:|
| Ray head | head (m6i.large) | 0.5 / 1.5 | 1.5 / 2.5 GiB | — | 1 |
| FastAPI/QA handler (Ray Serve) | head | 0.3 / 0.8 | 0.5 / 1 GiB | — | 1 |
| Embedder (Ray Serve actor) | head | 1.0 / 1.0 | 0.5 / 1.5 GiB | — | 1 |
| Qdrant StatefulSet | head | 0.3 / 1.0 | 0.5 / 2 GiB | — | 1 |
| **vllm-openai StatefulSet** | gpu (g6/g5) | 3 / 3.5 | 12 / 14 GiB | **1** | 1 |

> Head packing: 2.1 vCPU req / 3 GiB req trên 2 vCPU / 8 GiB node. CPU req hơi over, **giảm Embedder req xuống 0.7** hoặc upgrade head lên `m6i.xlarge` nếu thấy throttling.
>
> Cluster floor: 2 nodes (head + gpu) = 6 vCPU + 24 GiB + 1 GPU. Headroom đủ cho demo.

GPU pod yêu cầu:
```yaml
resources:
  limits:
    nvidia.com/gpu: 1
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
nodeSelector:
  node-type: gpu-worker
```

### 4.3 Terraform split — persistent vs ephemeral

```
infra/environments/dev/
├── persistent/                    # tạo 1 lần, KHÔNG destroy
│   ├── main.tf                    # VPC, S3 bucket, ECR repo, IAM/OIDC, EBS volumes
│   ├── outputs.tf                 # vpc_id, subnet_ids, ebs_volume_ids
│   └── terraform.tfstate          # S3 backend, key: dev/persistent.tfstate
└── ephemeral/                     # destroy/recreate hằng buổi
    ├── main.tf                    # EKS, node groups, KubeRay, observability, app
    ├── data.tf                    # remote_state đọc từ persistent
    └── terraform.tfstate          # key: dev/ephemeral.tfstate
```

#### 4.3.1 `persistent/` — tạo 1 lần ($5–10/tháng đứng yên)

```hcl
# VPC + subnets — lab mode: public subnet cho workers, không NAT
module "network" {
  source = "../../../modules/network"
  enable_nat_gateway = false
  workers_in_public_subnet = true   # lab-mode trade-off
  lifecycle { prevent_destroy = true }
}

# EBS volumes pre-created (managed outside cluster lifecycle)
resource "aws_ebs_volume" "qdrant_data" {
  availability_zone = var.worker_az         # phải cùng AZ với gpu-worker MNG
  size              = 10
  type              = "gp3"
  encrypted         = true
  tags = { Name = "qdrant-data-retain" }
  lifecycle { prevent_destroy = true }
}

resource "aws_ebs_volume" "llm_cache" {
  availability_zone = var.worker_az
  size              = 20
  type              = "gp3"
  encrypted         = true
  lifecycle { prevent_destroy = true }
}

# S3 bucket — raw docs + Qdrant snapshots + Terraform state
resource "aws_s3_bucket" "data" {
  bucket = "${var.project}-data-${var.account_id}"
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration { status = "Enabled" }    # snapshot history
}

# ECR — images stay even when cluster down
resource "aws_ecr_repository" "app" {
  name                 = "${var.project}-app"
  image_tag_mutability = "MUTABLE"           # lab; prod = IMMUTABLE
  force_delete         = false
  lifecycle { prevent_destroy = true }
}

# IAM OIDC for GitHub Actions — keep, $0
resource "aws_iam_openid_connect_provider" "github" { ... }

output "vpc_id"           { value = module.network.vpc_id }
output "public_subnets"   { value = module.network.public_subnet_ids }
output "qdrant_volume_id" { value = aws_ebs_volume.qdrant_data.id }
output "ecr_url"          { value = aws_ecr_repository.app.repository_url }
output "data_bucket"      { value = aws_s3_bucket.data.id }
```

#### 4.3.2 `ephemeral/` — destroy/recreate thoải mái

```hcl
data "terraform_remote_state" "persistent" {
  backend = "s3"
  config = {
    bucket = "llm-chat-tfstate"
    key    = "dev/persistent.tfstate"
    region = "us-west-2"
  }
}

locals {
  vpc_id            = data.terraform_remote_state.persistent.outputs.vpc_id
  qdrant_volume_id  = data.terraform_remote_state.persistent.outputs.qdrant_volume_id
}

module "eks" {
  source     = "../../../modules/eks"
  vpc_id     = local.vpc_id
  subnet_ids = data.terraform_remote_state.persistent.outputs.public_subnets
  # node groups: head t4g.large, gpu-worker g5.xlarge (SPOT), vector-db r7g.large
}

# Bind Qdrant PV vào EBS volume đã có trong persistent
resource "kubectl_manifest" "qdrant_pv" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "PersistentVolume"
    metadata   = { name = "qdrant-data-pv" }
    spec = {
      capacity                      = { storage = "10Gi" }
      accessModes                   = ["ReadWriteOnce"]
      persistentVolumeReclaimPolicy = "Retain"
      storageClassName              = "gp3-retain"
      csi = {
        driver       = "ebs.csi.aws.com"
        volumeHandle = local.qdrant_volume_id   # ⬅ EBS đã có
        fsType       = "ext4"
      }
    }
  })
  depends_on = [module.eks]
}
```

### 4.4 Cost analysis (us-west-2, destroy/recreate, rev 2)

**Active 80h/tháng** (~2.5h × 24 buổi/tháng):

| Item | Rate | Hours | $/tháng |
|---|---:|---:|---:|
| EKS control plane | $0.10/h | 80 | $8.00 |
| g6.xlarge spot (L4, primary) | $0.32/h | 80 | **$25.60** |
| m6i.large head spot | $0.030/h | 80 | $2.40 |
| EBS root nodes (2 node × 20 GiB, prorated 80h) | — | 80 | $1.50 |
| EBS Qdrant PVC 10 GiB (Retain, always) | $0.08/GB-mo | 720 | $0.80 |
| EBS LLM cache 20 GiB (Retain, always) | $0.08/GB-mo | 720 | $1.60 |
| S3 (docs + snapshots, ~10 GiB) | $0.023/GB-mo | always | $0.25 |
| ECR (app image ~1.5 GiB; vllm pulled from upstream) | $0.10/GB-mo | always | $0.15 |
| Data transfer (CloudWatch + image pull) | — | — | $3.00 |
| **Total (g6.xlarge)** | | | **~$43/tháng** |
| **Total (g5.xlarge fallback)** | (+$6.4) | | **~$49/tháng** |

> So với rev 1 (~$54): tiết kiệm **$5–10/tháng** bằng cách (a) bỏ vector-db node ($3), (b) chọn g6 thay g5 ($6.4), (c) ECR nhỏ hơn vì không bake model + không dùng custom GPU image ($1).

→ Còn dư **$40–47 buffer** trong budget $90/tháng. Có thể:
- Tăng active lên **150h/tháng** → ~$77/tháng vẫn dưới budget.
- Hoặc thêm **on-demand fallback** GPU node trong demo quan trọng (overhead ~$4/buổi).
- Hoặc **giữ buffer** cho việc reindex / load test / scale-up scratch.

### 4.5 Lifecycle commands

```makefile
# Makefile
.PHONY: cluster-up cluster-down cluster-status snapshot-qdrant

cluster-up:
	cd infra/environments/dev/ephemeral && terraform apply -auto-approve
	./scripts/wait_pods_ready.sh
	@echo "✓ Cluster ready (~$(./scripts/estimate_session_cost.sh)/h)"

cluster-down: snapshot-qdrant
	cd infra/environments/dev/ephemeral && terraform destroy -auto-approve
	@echo "✓ Cluster destroyed. Data preserved: EBS + S3 + ECR."

cluster-status:
	@aws eks list-clusters --region us-west-2 | jq .
	@kubectl get nodes 2>/dev/null || echo "(no cluster running)"

snapshot-qdrant:
	@if kubectl get pod -n llm-chat qdrant-0 >/dev/null 2>&1; then \
	  kubectl exec -n llm-chat qdrant-0 -- \
	    curl -sX POST localhost:6333/collections/documents/snapshots ; \
	  kubectl cp llm-chat/qdrant-0:/qdrant/snapshots/ ./qdrant-snap/ ; \
	  aws s3 sync ./qdrant-snap s3://llm-chat-data/qdrant-backup/$$(date +%F)/ ; \
	  rm -rf ./qdrant-snap ; \
	fi
```

GitHub Actions workflow tự động:
```yaml
# .github/workflows/cluster-lifecycle.yml — manual trigger
name: cluster-lifecycle
on:
  workflow_dispatch:
    inputs:
      action: {type: choice, options: [up, down], required: true}
permissions: {id-token: write, contents: read}
jobs:
  toggle:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with: {role-to-assume: ${{ secrets.AWS_OIDC_ROLE }}, aws-region: us-west-2}
      - uses: hashicorp/setup-terraform@v3
      - run: make cluster-${{ inputs.action }}
```

### 4.6 Spot eviction handling

```hcl
gpu_worker = {
  instance_types       = ["g6.xlarge", "g5.xlarge", "g4dn.xlarge"]   # diversify, ưu tiên g6
  capacity_type        = "SPOT"
  spot_allocation_strategy = "capacity-optimized-prioritized"
  on_demand_percentage = 0
  min_size             = 0
  desired_size         = 1
  max_size             = 2
  labels = { "node-type" = "gpu-worker" }
  taints = [{
    key = "nvidia.com/gpu", value = "true", effect = "NO_SCHEDULE"
  }]
}
```

Mitigation:
- AWS Node Termination Handler (đã có) cordon node 2 min trước eviction.
- `terminationGracePeriodSeconds: 180` để vLLM drain in-flight requests.
- PDB `minAvailable: 0` cho GPU worker (1 node = single point; demo chấp nhận downtime 5 min nếu evict).
- Trước demo quan trọng: bật fallback on-demand bằng `terraform apply -var gpu_capacity_type=ON_DEMAND` (overhead chỉ trong session đó: $1 × 4h = $4).

---

## 5. Performance budget

### 5.1 Latency target (p95) — GPU stack

| Step | Target | Đo ở đâu | Note |
|---|---:|---|---|
| /qa total (top_k=5) | **12 s** | Client | hard SLA cho MVP |
| ├── Embed query | 100 ms | Ray Serve metric | e5-small INT8 trên CPU Graviton, batch=1 |
| ├── Qdrant search | 50 ms | Qdrant histogram | top-5 ANN, 50K vectors |
| ├── Prompt build | 5 ms | Server log | string concat |
| └── ChatModel (vLLM + AWQ 7B) | **~7 s** | Ray Serve | prefill 3.3K @ 2K tok/s + decode 400 @ 80 tok/s |

Detail ChatModel breakdown:
- Prefill 3,300 token / 2,000 tok/s = **1.65 s**
- Decode 400 token / 80 tok/s = **5.0 s**
- vLLM scheduler + kernel launch overhead = ~0.3 s
- **Sub-total = ~7 s** — đạt SLA với buffer.

So sánh với CPU stack ban đầu:
| Stack | Prefill 3.3K tok | Decode 400 tok | Total ChatModel |
|---|---:|---:|---:|
| llama.cpp 0.6B Q4 trên Graviton3 4 vCPU | 27 s | 13 s | 40 s |
| llama.cpp 1.5B Q4 trên c8g.2xlarge 8 vCPU | 22 s | 20 s | 42 s |
| **vLLM 7B AWQ trên g5.xlarge A10G** | **1.65 s** | **5.0 s** | **7 s** |
| vLLM 14B AWQ trên g5.xlarge A10G | 2.5 s | 8 s | 10.5 s |

### 5.2 Throughput

vLLM **continuous batching** — không lock 1 actor cho 1 request như llama.cpp:
- 1 GPU = 1 actor = N concurrent requests (capped bằng `max_num_seqs=16`).
- A10G với Qwen2.5-7B AWQ: serve được **8–16 req đồng thời** ở mức decode tốc độ 30–60 tok/s mỗi request.
- Steady-state throughput cluster: **~1–2 req/s** cho demo 10–20 user.

Scale-up bằng cách thêm GPU node (autoscaler):
- `gpu-worker.max_size = 2` → 2 GPU = 2 Ray actor = 16–32 concurrent.
- Cost +$32/tháng nếu chạy 80h.

### 5.3 Cold start (rev 2)

| Component | Cold time | Mitigation |
|---|---:|---|
| EC2 spot allocation (g6/g5.xlarge) | 60–120 s | Capacity-optimized spot diversified (g6 > g5 > g4dn); fallback on-demand cho demo |
| EKS node ready | 90 s (cAdvisor + kubelet join) | — |
| NVIDIA driver init | 15 s | DaemonSet warm sẵn từ image plugin |
| Image pull `vllm/vllm-openai` (7 GiB upstream) | 90 s | First time / cluster-up; EBS llm-cache giúp model load tránh re-download |
| Image pull app (1.5 GiB ECR) | 15 s | — |
| vLLM model load (5 GB AWQ từ EBS llm-cache → VRAM) | 12 s | Persistent EBS cache → không re-download HF |
| CUDA graph capture | 8 s | One-time per replica |
| Ray Serve + FastAPI ready | 5 s | — |
| **Total cold start** (1st `cluster-up`) | **~4–5 phút** | Subsequent cluster-up nhanh hơn vì EBS cache + image cache trên ECR cache layer |

`cluster-up` end-to-end timeline:
```
T+0:00  terraform apply (EKS + nodegroups)
T+5:00  EKS cluster ACTIVE
T+8:00  Nodes Ready (head + gpu), NVIDIA plugin scheduled, EBS CSI driver up
T+10:00 PV qdrant-data-pv + llm-cache-pv bind to retained EBS volumes
T+11:30 Qdrant StatefulSet Ready (head), data có ngay từ session trước
T+12:30 App pod (FastAPI + Embedder) Ready trên head
T+13:30 vllm-openai pod pull + model load (5GB từ EBS) + CUDA graph
T+14:30 /qa endpoint responsive ✓ (test với 1 câu)
```

---

## 6. Observability extension

Mở rộng dashboard hiện tại (`infra/modules/observability/dashboards/llm-chat-app.json`).

### 6.1 Metrics mới (Prometheus)

```python
# app/metrics.py
from prometheus_client import Counter, Histogram, Gauge

INGEST_REQUESTS  = Counter("ingest_requests_total", ["status"])
INGEST_DURATION  = Histogram("ingest_duration_seconds", ["mime_type"], buckets=[1,5,10,30,60,120])
INGEST_CHUNKS    = Histogram("ingest_chunks_per_doc", buckets=[10,50,100,500,1000])

EMBED_REQUESTS   = Counter("embed_requests_total")
EMBED_LATENCY    = Histogram("embed_latency_seconds", ["batch_size_bucket"], buckets=[0.01,0.05,0.1,0.5,1])
EMBED_BATCH_SIZE = Histogram("embed_batch_size", buckets=[1,4,8,16,32])

QDRANT_SEARCH_LATENCY = Histogram("qdrant_search_latency_seconds", buckets=[0.01,0.05,0.1,0.5])
QDRANT_TOP1_SCORE     = Histogram("qdrant_top1_score", buckets=[0.3,0.5,0.7,0.85,0.95])
QDRANT_RESULT_COUNT   = Histogram("qdrant_result_count", buckets=[0,1,3,5,10])

QA_LATENCY       = Histogram("qa_e2e_latency_seconds", ["status"], buckets=[1,3,5,8,15,30,60])
QA_TOKEN_USAGE   = Histogram("qa_prompt_tokens", buckets=[500,1000,2000,3000,4000])
QA_FALLBACK      = Counter("qa_fallback_total", ["reason"])  # no_hits|low_score|llm_dontknow

LLM_PREFILL_TPS  = Histogram("llm_prefill_tokens_per_sec", buckets=[20,50,80,120,200])
LLM_DECODE_TPS   = Histogram("llm_decode_tokens_per_sec", buckets=[10,20,30,50,80])
LLM_CONTEXT_USED = Histogram("llm_context_tokens_used", buckets=[500,1000,2000,3000,3500,4000])
```

### 6.2 Grafana panels mới (`rag-pipeline.json`)

1. **QA E2E latency** (p50/p95/p99 stacked) — segment by step (embed/search/llm).
2. **Token throughput**: prefill_tps vs decode_tps over time.
3. **Retrieval quality**: histogram top1 score; alert nếu p50 < 0.4 (chunking/embedding kém).
4. **Fallback rate** by reason — % "không tìm thấy".
5. **Ingestion throughput**: docs/min + p95 ingest_duration.
6. **Qdrant memory + disk usage** (qdrant exporter `:6333/metrics`).
7. **Context utilization**: % requests dùng > 80% n_ctx → alert tăng n_ctx.

### 6.3 Tracing (Phase 2)

OpenTelemetry → tempo. Span chain:
```
qa_request
├── embed_query              (Embedder actor)
├── qdrant_search            (gRPC client)
├── prompt_build             (server)
└── llm_generate             (ChatModel actor)
    ├── prefill              (token count, duration)
    └── decode               (token count, duration)
```

---

## 7. Failure modes & runbook

| Failure | Detection | User-facing | Recovery |
|---|---|---|---|
| Qdrant pod OOM | restart loop, alert | 503 from /qa | Increase RAM limit OR enable `on_disk: true` cho vector |
| Worker pod OOM (KV cache leak) | OOMKilled | upstream timeout | Reduce `actors_per_pod` to 1; check `n_ctx` |
| Embedder backed up (queue depth high) | `embed_latency_p95 > 1s` | high QA latency | Autoscale Embedder up; check ONNX session threads |
| Spot eviction | NodeShutdown event | brief 503 | NTH cordon + new node 2 min |
| HF/S3 unreachable on ingest | ingest_failures_total spike | doc stuck `processing` | Background retry job; manual re-trigger |
| LLM hallucination (eval drift) | eval script weekly | sai sự thật | Update prompt; check chunking quality |
| Vector DB full (PVC 100%) | `kubelet_volume_stats_used_bytes` alert | ingest fails | Resize PVC (`kubectl edit pvc`, gp3 supports online resize) |
| Sao cũng không hit top-k | `qa_fallback_total{reason="no_hits"}` spike | "không tìm thấy" cho mọi câu | Check Qdrant collection size; reindex |

Runbook entries thêm vào `docs/runbook.md`:
- **R-RAG-001:** Re-index toàn bộ documents (khi đổi embedding model).
- **R-RAG-002:** Clear partial chunks của 1 doc (sau ingest crash).
- **R-RAG-003:** Resize Qdrant PVC.

---

## 8. Security considerations (lab-mode scope)

| Aspect | Decision | Lý do |
|---|---|---|
| Auth on /documents, /qa | **None** (lab) | Trừ khi review yêu cầu. Có thể bolt JWT qua middleware sau. |
| S3 bucket policy | Private + IAM role cho EKS service account (IRSA) | Standard |
| File upload sanitization | MIME check + size cap + sha256 dedup | Đủ cho lab |
| Prompt injection ("ignore previous instructions" trong doc) | Soft mitigation qua system prompt; **không** hard sanitize | RAG không phải zero-trust system |
| PII trong doc | Out of scope MVP — note rằng documents được vector hoá đầy đủ |

---

## 9. Implementation plan

### 9.1 Phase breakdown (rev 2 — GPU skeleton trước RAG)

> **Nguyên tắc reorder:** không nhảy thẳng vào RAG khi infra GPU chưa pass `vllm /chat` benchmark. Risk lớn nhất là image arch mismatch + spot capacity. Validate trước, build RAG sau.

| Phase | Mục tiêu | Output | Effort |
|---|---|---|---:|
| **P0** Persistent stack | VPC (x86 subnet, no NAT) + S3 + ECR + EBS volumes (qdrant 10Gi, llm-cache 20Gi) + IAM/OIDC | `infra/environments/dev/persistent/` apply ok | 0.5 ngày |
| **P1** Ephemeral x86 GPU skeleton | EKS + 2 node groups (head m6i.large, gpu g6/g5 spot diversified), EBS CSI driver, NVIDIA device plugin, DCGM exporter, Makefile cluster-up/down | `kubectl get node -l node-type=gpu-worker -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}'` = 1; `cluster-up` < 15 phút | 1 ngày |
| **P2** vLLM `/chat` benchmark | Deploy `vllm/vllm-openai:latest-stable` StatefulSet với Qwen2.5-7B-AWQ; smoke `curl /v1/chat/completions`; bench prefill/decode | `reports/p2-vllm-bench.md` (prefill ≥ 1500 tok/s, decode ≥ 60 tok/s, total /chat < 8s); FastAPI proxy `/chat` qua OpenAI client | 1 ngày |
| **P3** Qdrant collocate + PV bind | StatefulSet trên head x86 với taint toleration; PV bind vào EBS retained `vol-XXXX`; collection schema | upsert + search ok; destroy/recreate cluster → `points_count` còn nguyên | 0.5 ngày |
| **P4** Embedder | Export e5-small → ONNX INT8 (build trong app image); Ray Serve `Embedder` pinned head | `/embed` batch=1 < 100 ms, batch=32 < 500 ms | 1 ngày |
| **P5** Ingest pipeline | `/documents` POST/GET/DELETE; Ray Task async; S3 raw; SHA-256 dedup; cron cleanup stuck-processing | upload PDF 50-page → ready < 60s | 1 ngày |
| **P6** RAG `/qa` flow | embed → qdrant search → prompt build → vllm-openai HTTP; VN prompt template; sources[] | 5 câu test pass, p95 < 12s; faithfulness manual check 5/5 | 1 ngày |
| **P7** Frontend extension | Upload form + doc list + ingest status polling + QA box + source citations (xem §3.6) | demo end-to-end browser | 0.5–1.5 ngày (HTMX vs React) |
| **P8** Observability | RAG dashboard Grafana (6 panel) + GPU metrics (DCGM exporter) + vLLM `/metrics` scrape | dashboard có data thực | 0.5 ngày |
| **P9** Eval + seed data | Wikipedia VN + Aposa docs seed; 50-câu eval set; recall@5 measurement; reranker A/B nếu recall < 0.75 | `tests/rag_eval/vn_50.jsonl`, eval report; quyết định có thêm reranker | 1 ngày |
| **P10** Docs + ADR | `rag-quickstart.md`, runbook R-RAG-001/002/003, ADR-006/007/008 | docs đầy đủ | 0.5 ngày |
| **Total** | | | **~8.5–9.5 ngày** |

### 9.2 MVP scope (1 buổi demo — 6h)

**Tiền điều kiện:** P0 + P1 (persistent stack + ephemeral skeleton) đã có sẵn từ trước. Trong buổi:

| Khung giờ | Việc | Output |
|---|---|---|
| 09:00–10:30 | `make cluster-up` + verify pods ready; deploy Qdrant (P3) | Cluster + Qdrant smoke test ok |
| 10:30–12:00 | Embedder pinned head + ingest 1 PDF sync inline (P4 + P5 minimal) | 1 doc ingested, có chunks trong Qdrant |
| 13:00–14:30 | QA endpoint + prompt template VN (P6) | `/qa` trả lời 5 câu test với sources |
| 14:30–15:30 | UI upload + chat (P7) | Demo browser end-to-end |
| 15:30–16:30 | Seed thêm 5 doc (Wikipedia + Aposa) + chuẩn bị 10 câu hỏi (P9 minimal) | Bộ demo data sẵn sàng |
| 16:30–17:00 | `make cluster-down` snapshot + destroy; viết short doc | Doc + clean state |

### 9.3 Definition of done (production-ready, không phải MVP)

- [ ] `/qa` p95 < 12s với top_k=5, max_model_len=8192 (đo qua `scripts/load_test.py` 100 req)
- [ ] Recall@5 ≥ 0.80 trên VN eval set 50 câu
- [ ] Faithfulness ≥ 0.70 (manual review 50 câu)
- [ ] Out-of-domain refusal rate ≥ 0.90 ("không tìm thấy")
- [ ] Ingest 100-page PDF < 90s
- [ ] Qdrant data sống qua `cluster-down`/`cluster-up` (PV bind back EBS retained)
- [ ] Spot eviction trên GPU node → vLLM drain in-flight < 3 min, cluster tự scale lên node mới
- [ ] Grafana RAG dashboard 6+ panel có data thực (latency breakdown, retrieval score, GPU util, ingest queue, fallback rate, cost-per-session)
- [ ] 5 ADRs: 006-gpu-pivot, 007-persistent-ephemeral-split, 008-vllm-over-llamacpp, 009-awq-quantization, 010-embedder-pin-head
- [ ] Runbook 3 entries: R-RAG-001 reindex, R-RAG-002 cleanup partial chunks, R-RAG-003 restore Qdrant from S3 snapshot
- [ ] Cost report 30-day: actual < $90/tháng với 60–80h active

---

## 10. Open questions & risks

| # | Question / Risk | Plan |
|---|---|---|
| Q1 | vLLM 7B AWQ prefill thực tế trên A10G = ? | **P2 bench bắt buộc** với `scripts/bench_vllm.py`. Nếu < 1,500 tok/s, debug awq_marlin kernel + check CUDA graph. |
| Q2 | FP8 KV cache trên A10G ảnh hưởng quality? | A/B test trên eval set: `kv_cache_dtype="fp8_e5m2"` vs `"auto"`. Accept nếu drop ≤ 1% recall. |
| Q3 | ONNX Runtime ARM64 embedder throughput? | P4 bench. Target ≥ 50 sent/s batch=32. |
| Q4 | Streaming response qua Ray Serve? | vLLM hỗ trợ AsyncStream; Ray Serve `StreamingResponse`. Phase 2 cho UX. |
| Q5 | Multi-tenant / per-user collections? | Out of scope MVP; tăng filter `user_id` vào Qdrant payload sau. |
| R1 | EBS volume bind sai AZ sau cluster-up | Pin worker AZ cố định trong tfvars; check `aws_ebs_volume.availability_zone == nodegroup.subnet.az`. |
| R2 | PV stuck `Released` sau destroy/recreate (claimRef cũ) | `kubectl patch pv qdrant-data-pv -p '{"spec":{"claimRef":null}}'` để re-bind. Document trong runbook R-RAG-003. |
| R3 | Spot g5.xlarge bị evict giữa demo | Pre-warm 1 on-demand node 30 phút trước demo: `terraform apply -var gpu_capacity_type=ON_DEMAND`. |
| R4 | Image pull 12 GiB chậm | Pre-pull qua DaemonSet `image-puller` chạy ngay khi node Ready. |
| R5 | Cluster-up 14 phút hơi lâu cho demo trực tiếp | Document trong runbook: "khởi tạo cluster ≥ 15 min trước demo". |
| R6 | LLM bịa số liệu (hallucination) | Soft constraint qua prompt; Phase 2 grounding check (regex numbers → verify trong context). |
| R7 | Snapshot Qdrant fail giữa chừng | Snapshot dùng `Retain` reclaim — data trong PVC vẫn còn; S3 snapshot chỉ là backup thứ 2. |
| R8 | NVIDIA driver mismatch với CUDA wheel | Dùng official `vllm/vllm-openai:latest-stable` (đã test combo torch/CUDA/vLLM/autoawq). Pin tag immutable cho production. |
| R9 | ARM head + x86 GPU image mismatch (đã fix rev 2) | Head x86 m6i.large; tất cả Ray pod share image `linux/amd64`. Không build ARM image cho path RAG. |
| R10 | Ingest mất khi cluster destroy giữa chừng | Idempotent SHA-256 → user re-upload là OK; cron cleanup `status=processing > 5min` → mark failed + xoá partial Qdrant chunks. |
| R11 | Qdrant collocate head bị OOM khi scale lên (rev 2) | Alert `container_memory_usage > 6 GiB` trên head → tách Qdrant ra `r7g.large` node group; document trong runbook R-RAG-004. |

---

## 11. References

- **Model:** `Qwen/Qwen2.5-7B-Instruct-AWQ` (HF). Upgrade candidate sau eval: `Qwen/Qwen2.5-14B-Instruct-AWQ`.
- **vLLM:** official image `vllm/vllm-openai:latest-stable` (KHÔNG pin 0.6.3 nữa — image upstream là source of truth). Features dùng: `awq_marlin` kernel, FP8 KV cache (`kv_cache_dtype=fp8_e5m2`).
- **NVIDIA L4 (g6):** 24 GB GDDR6, 121 TFLOPS FP16, Ada arch (2023) — **primary**.
- **NVIDIA A10G (g5):** 24 GB GDDR6, 250 TFLOPS FP16, Ampere arch — fallback.
- **NVIDIA T4 (g4dn):** 16 GB GDDR6, 65 TFLOPS FP16, Turing arch — cheap fallback (no FP8 KV).
- **Qdrant docs:** quantization, on-disk + memmap, snapshots.
- **Embedding:** `intfloat/multilingual-e5-small` (Wang et al., 2024). Phase 2 candidates: `BAAI/bge-m3`, `BAAI/bge-reranker-v2-m3`.
- **EC2 spot pricing snapshot us-west-2 (2026-05):** m6i.large $0.030/h, g6.xlarge $0.32/h, g5.xlarge $0.40/h, g4dn.xlarge $0.21/h.
- **Persistent/ephemeral pattern:** `lifecycle.prevent_destroy` + remote_state cross-stack reads.
- **Frontend:** HTMX 1.9+ (htmx.org), Alpine.js 3.x. React+Vite reserved cho Phase 11+.
- ADRs cũ: [`002-graviton-arm-nodes.md`](adr/002-graviton-arm-nodes.md) (sẽ deprecate cho path RAG — Graviton chỉ còn ý nghĩa cho path CPU-only `llm-chat`), [`001-ray-serve-on-kuberay.md`](adr/001-ray-serve-on-kuberay.md).
- ADRs mới (sẽ tạo):
  - `006-gpu-pivot-for-rag.md` — vì sao đổi ARM CPU sang x86 GPU cho RAG.
  - `007-persistent-ephemeral-split.md` — Terraform state split + EBS Retain.
  - `008-vllm-openai-server-pattern.md` — vì sao tách vllm-openai server thay vì Ray actor wrap.
  - `009-awq-quantization.md` — AWQ Marlin + FP8 KV trade-off.
  - `010-qdrant-collocate-head.md` — vì sao bỏ dedicated vector-db node ở MVP.

---

## 12. Appendix A — env var reference

### 12.1 vllm-openai server args (rev 2 — truyền qua container `args`)

| Arg | Default | Range | Note |
|---|---|---|---|
| `--model` | `Qwen/Qwen2.5-7B-Instruct-AWQ` | HF repo | server load lần đầu vào EBS llm-cache, lần sau đọc từ cache |
| `--quantization` | `awq_marlin` | awq/awq_marlin/gptq | marlin nhanh hơn awq cũ ~2x |
| `--max-model-len` | 8192 | 2048–32768 | trade-off VRAM |
| `--gpu-memory-utilization` | 0.85 | 0.5–0.95 | càng cao càng nhiều KV slot |
| `--kv-cache-dtype` | `fp8_e5m2` | auto/fp8_e5m2/fp8_e4m3 | g6 (L4) / g5 (A10G) hỗ trợ; g4dn (T4) **KHÔNG** |
| `--max-num-seqs` | 16 | 1–256 | concurrent decode cap |
| `--enforce-eager` | false | bool | true để debug, false dùng CUDA graph |
| `--swap-space` | 4 | 0–32 | GiB CPU↔GPU swap khi KV pool full |
| `--served-model-name` | `qwen-rag` | str | model id mà OpenAI client gọi |
| `--dtype` | `float16` | float16/bfloat16 | bfloat16 chỉ trên Ampere+ (ok cho A10G/L4) |

### 12.1b QA handler env (client proxy đến vllm-openai)

| Env var | Default | Note |
|---|---|---|
| `VLLM_BASE_URL` | `http://vllm-server-0.vllm-server.llm-chat:8000/v1` | cluster DNS nội bộ |
| `VLLM_SERVED_MODEL` | `qwen-rag` | match `--served-model-name` |
| `MAX_NEW_TOKENS` | 400 | server cap khi gọi `/v1/chat/completions` |
| `MAX_INPUT_TOKENS` | 4000 | reject prompt vượt trước khi gửi cho vLLM |
| `VLLM_TIMEOUT_S` | 60 | httpx timeout |

### 12.2 Embedder (CPU ONNX trên head x86)

| Env var | Default | Range | Note |
|---|---|---|---|
| `EMBEDDER_MODEL_PATH` | `/models/embedder-onnx-int8` | path | baked vào app image (~80 MiB) |
| `EMBEDDER_BATCH_SIZE` | 32 | 1–64 | ingest batch; query luôn 1 |
| `EMBEDDER_NUM_THREADS` | 1 | 1–2 | m6i.large 2 vCPU; share với Ray head + Qdrant |
| `EMBEDDER_PREFIX_QUERY` | `query: ` | str | bắt buộc cho e5 — sai recall -15% |
| `EMBEDDER_PREFIX_PASSAGE` | `passage: ` | str | bắt buộc cho e5 |

### 12.3 Qdrant client

| Env var | Default | Range | Note |
|---|---|---|---|
| `QDRANT_HOST` | `qdrant.llm-chat.svc.cluster.local` | DNS | service trong namespace |
| `QDRANT_GRPC_PORT` | 6334 | | gRPC nhanh hơn HTTP ~30% |
| `QDRANT_COLLECTION` | `documents` | | |
| `QDRANT_TOP_K` | 5 | 1–20 | |
| `QDRANT_SCORE_THRESHOLD` | 0.5 | 0–1 | dưới ngưỡng → "không tìm thấy" |
| `QDRANT_HNSW_EF` | 128 | 32–512 | search-time HNSW depth |

### 12.4 Ingest pipeline

| Env var | Default | Range | Note |
|---|---|---|---|
| `S3_BUCKET` | từ persistent output | | raw docs + snapshots |
| `S3_PREFIX_DOCS` | `docs/` | | |
| `S3_PREFIX_SNAPSHOTS` | `qdrant-backup/` | | |
| `MAX_UPLOAD_BYTES` | 52428800 (50 MiB) | | |
| `CHUNK_SIZE_TOKENS` | 500 | 200–1500 | trade-off recall/context cost |
| `CHUNK_OVERLAP_TOKENS` | 80 | 0–200 | ~15% chunk_size |
| `INGEST_BATCH_SIZE` | 32 | 1–64 | chunks/batch gọi Embedder |
| `INGEST_TIMEOUT_S` | 300 | 60–1800 | per-doc timeout |

### 12.5 Cluster lifecycle

| Env var | Default | Note |
|---|---|---|
| `CLUSTER_NAME` | `llm-chat-dev` | EKS cluster name |
| `AWS_REGION` | `us-west-2` | |
| `TF_VAR_gpu_capacity_type` | `SPOT` | flip sang `ON_DEMAND` trước demo quan trọng |
| `TF_VAR_active_hours_target` | 80 | dùng để tính cost projection |

---

## 13. Appendix B — quick smoke test checklist

```bash
# === A. Setup persistent (1 lần) ===
cd infra/environments/dev/persistent
terraform init && terraform apply
# Outputs: vpc_id, qdrant_volume_id, ecr_url, data_bucket

# === B. Mỗi phiên làm việc ===

# 1. Bật cluster
make cluster-up   # ~14 phút end-to-end
make cluster-status

# 2. Verify infra
kubectl get nodes -o wide
kubectl get node -l node-type=gpu-worker -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}'
# Expect: 1

# 3. Qdrant alive + data còn nguyên từ session trước
kubectl -n llm-chat exec qdrant-0 -- curl -s localhost:6333/readyz
kubectl -n llm-chat exec qdrant-0 -- \
  curl -s 'localhost:6333/collections/documents' | jq '.result.points_count'

# 4. Embedder (CPU, pinned head)
APP=$(kubectl -n llm-chat get svc llm-chat-serve-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -X POST http://$APP/embed \
  -H 'content-type: application/json' \
  -d '{"texts": ["query: hello"]}' | jq '.dim, (.vectors[0]|length)'

# 5. vllm-openai server (GPU) — direct test qua port-forward trước khi qua proxy
kubectl -n llm-chat port-forward svc/vllm-server 8000:8000 &
curl -s http://localhost:8000/v1/models | jq .         # expect served-model-name=qwen-rag
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"qwen-rag","messages":[{"role":"user","content":"2+2?"}],"max_tokens":50}' | jq .

# 5b. ChatModel via FastAPI proxy
curl -X POST http://$APP/chat \
  -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"Trả lời ngắn: 2+2 là?"}]}' | jq .

# 6. Ingest 1 PDF
curl -X POST http://$APP/documents \
  -F 'file=@seed/wiki/sample.pdf' | jq '.doc_id, .status'
# Wait ready
for i in {1..30}; do
  STATUS=$(curl -s http://$APP/documents/<doc_id> | jq -r .status)
  [ "$STATUS" = "ready" ] && break
  sleep 2
done

# 7. QA end-to-end
curl -X POST http://$APP/qa \
  -H 'content-type: application/json' \
  -d '{"question": "Aposa hỗ trợ những loại token nào?", "top_k": 5}' \
  | jq '{answer, sources: [.sources[] | {doc_title, chunk_idx, score}], latency_ms}'

# 8. Eval recall@5 (offline)
python scripts/eval_rag.py tests/rag_eval/vn_50.jsonl --top-k 5 \
  --target-recall 0.80 --target-faithfulness 0.70

# 9. Bench GPU prefill/decode
python scripts/bench_vllm.py \
  --prompt-tokens 3300 --new-tokens 400 --concurrency 1,4,8 \
  --out reports/p2-vllm-bench.md

# === C. Tắt cluster ===
make cluster-down    # snapshot Qdrant → S3, destroy ephemeral, giữ persistent
# Verify cost: aws ce get-cost-and-usage ...
```
