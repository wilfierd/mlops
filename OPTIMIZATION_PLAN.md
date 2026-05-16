# CPU Inference Optimization Plan

Muc tieu: giu kien truc **Ray Serve tren K8S/KubeRay**, nhung toi uu inference CPU that su bang **GGUF Q4_K_M + llama.cpp** cho model `Qwen3-0.6B`.

## Quyet dinh ky thuat

```text
Current:
  Ray Serve
    -> Python Transformers
    -> HF safetensors bf16
    -> torch model.generate()

Optimized:
  Ray Serve
    -> llama.cpp backend
    -> GGUF Q4_K_M
    -> CPU-native quantized inference
```

Ly do:

- `Qwen3-0.6B` bf16 chay duoc tren CPU, nhung PyTorch Transformers khong phai backend CPU latency tot nhat.
- `Q4_K_M` giam RAM va bandwidth memory, hop voi 4-8 vCPU hon.
- `llama.cpp` toi uu CPU inference tot hon cho GGUF, dac biet voi small LLM va CPU-only deployment.
- Ray/KubeRay van giu vai tro orchestration, autoscale, routing, deployment lifecycle.

## Model chot

| Muc | Gia tri |
| --- | --- |
| Model family | Qwen3 |
| Size | 0.6B |
| Runtime format | GGUF |
| Quantization | Q4_K_M |
| Thinking mode | off |
| Target use case | Chat ngan, tieng Viet/English, latency thap |

Model source can chon mot repo GGUF tin cay tren Hugging Face, vi du pattern:

```text
Qwen3-0.6B-Q4_K_M.gguf
```

Can pin ro:

- repo id
- file name
- checksum/SHA neu dung production

## Resource sizing

### Per replica

| Mode | CPU request | CPU limit | Memory request | Memory limit | Ghi chu |
| --- | ---: | ---: | ---: | ---: | --- |
| Minimum | 2 | 3 | 2Gi | 3Gi | Chay duoc, concurrency thap |
| Recommended | 3 | 4 | 3Gi | 4Gi | Can bang latency/chi phi |
| Stable load | 4 | 4 | 4Gi | 5Gi | It jitter hon khi concurrent |

Khuyen nghi ban dau:

```yaml
MODEL_NUM_CPUS: "3"
OMP_NUM_THREADS: "3"
LLAMA_ARG_THREADS: "3"
resources:
  requests:
    cpu: "3"
    memory: 3Gi
  limits:
    cpu: "4"
    memory: 4Gi
```

### Instance

| Muc tieu | Instance | Replica/node | Ghi chu |
| --- | --- | ---: | --- |
| Re nhat ARM | `m7g.xlarge` | 1 | 4 vCPU/16GiB, hop Q4 |
| Load test re | `m7g.2xlarge` | 2 | 8 vCPU/32GiB, de scale hon |
| x86 fallback | `m6i.xlarge` | 1 | Khong can ARM image |
| x86 load test | `m6i.2xlarge` | 2 | De build/deploy hon ARM |

Khuyen nghi:

```hcl
node_instance_types = ["m7g.xlarge"]
ray_replica_cpus    = 3
ray_replica_max     = 3
```

Neu benchmark concurrent:

```hcl
node_instance_types = ["m7g.2xlarge"]
ray_replica_cpus    = 3
ray_replica_max     = 4
```

## Kien truc optimized

```text
Client
  |
  v
K8S Service :8000
  |
  v
Ray Serve HTTP Proxy
  |
  v
ChatModel Replica
  |
  +-- FastAPI /chat
  +-- prompt formatting
  +-- llama.cpp binding/server call
  +-- GGUF Q4_K_M model
  |
  v
CPU tokens
```

## Hai cach implement

### Option A: llama-cpp-python trong Ray actor

```text
Ray Serve actor
  -> import llama_cpp.Llama
  -> load GGUF in __init__
  -> call llama.create_chat_completion()
```

Uu diem:

- Don gian ve topology.
- Moi Serve replica la mot process load model rieng.
- Autoscale replica truc tiep bang Ray Serve.
- Khong can sidecar/process manager.

Nhuoc diem:

- Build wheel `llama-cpp-python` ARM64 co the lau.
- Can kiem soat thread/env ky.

Khuyen nghi cho project nay: **Option A**.

### Option B: llama.cpp server sidecar/process

```text
Ray Serve actor
  -> HTTP call localhost llama.cpp server
  -> llama-server load GGUF
```

Uu diem:

- Tach backend inference thanh server OpenAI-compatible.
- De thay backend sau nay.

Nhuoc diem:

- Phuc tap hon trong lifecycle.
- Moi pod/replica can start subprocess/server.
- Healthcheck va cleanup phai can than.

## Thay doi code can lam

### 1. Them backend abstraction

File moi:

```text
app/backends/base.py
app/backends/transformers_backend.py
app/backends/llamacpp_backend.py
```

Env:

```text
INFERENCE_BACKEND=transformers|llamacpp
MODEL_ID=Qwen/Qwen3-0.6B
GGUF_REPO_ID=<repo>
GGUF_FILENAME=<file>
LLAMA_N_CTX=2048
LLAMA_N_THREADS=3
LLAMA_N_BATCH=128
ENABLE_THINKING=false
```

### 2. Implement llama.cpp backend

Pseudo:

```python
from llama_cpp import Llama

llm = Llama(
    model_path=model_path,
    n_ctx=2048,
    n_threads=3,
    n_batch=128,
    chat_format="chatml",
    verbose=False,
)

result = llm.create_chat_completion(
    messages=messages,
    temperature=0.7,
    top_p=0.8,
    max_tokens=max_new_tokens,
)
```

Qwen3 thinking off:

- Them system instruction ngan: `Do not use thinking mode. Answer directly.`
- Neu template/repo ho tro, them `/no_think` vao system hoac user prefix.
- Strip `<think>...</think>` output nhu fallback.

### 3. Dockerfile ARM64

Can build duoc:

```text
linux/amd64
linux/arm64
```

Them dependencies:

```text
llama-cpp-python
huggingface-hub
```

Build ARM64:

```bash
IMAGE_PLATFORM=linux/arm64 PRELOAD_MODEL=true ./infra/scripts/push_image.sh
```

Neu `llama-cpp-python` build qua QEMU qua cham, dung mot EC2 Graviton tam thoi de build native ARM64.

### 4. Preload GGUF

Docker build arg/env:

```text
GGUF_REPO_ID
GGUF_FILENAME
PRELOAD_GGUF=true
```

Trong Dockerfile:

```bash
python -c "from huggingface_hub import hf_hub_download; hf_hub_download(repo_id=..., filename=...)"
```

Runtime dung local cache:

```text
HF_HOME=/tmp/huggingface
```

### 5. K8S/RayService config

Default optimized:

```yaml
env:
  - name: INFERENCE_BACKEND
    value: llamacpp
  - name: ENABLE_THINKING
    value: "false"
  - name: LLAMA_N_CTX
    value: "2048"
  - name: LLAMA_N_THREADS
    value: "3"
  - name: LLAMA_N_BATCH
    value: "128"
resources:
  requests:
    cpu: "3"
    memory: 3Gi
  limits:
    cpu: "4"
    memory: 4Gi
```

Ray Serve:

```yaml
max_ongoing_requests: 1
target_ongoing_requests: 1
ray_actor_options:
  num_cpus: 3
```

Ly do: voi CPU-only va chua batching, moi replica xu ly 1 request la de du doan latency nhat.

## Benchmark plan

### Metrics can do

- Time to first successful request.
- p50/p95/p99 latency.
- tokens/sec approximate.
- replica distribution.
- pod scale-up time.
- memory RSS trong pod.
- CPU usage per pod.

### Test matrix

| Backend | Model | Instance | Replica CPU | Concurrency |
| --- | --- | --- | ---: | ---: |
| Transformers bf16 | Qwen3-0.6B | m7g.xlarge | 3 | 1, 2, 4 |
| llama.cpp Q4_K_M | Qwen3-0.6B | m7g.xlarge | 3 | 1, 2, 4 |
| llama.cpp Q4_K_M | Qwen3-0.6B | m7g.2xlarge | 3 | 1, 4, 8 |

Command:

```bash
python scripts/load_test.py \
  --url http://127.0.0.1:8000/chat \
  --concurrency 4 \
  --requests 40 \
  --warmup 4 \
  --max-new-tokens 64 \
  --output reports/qwen3-06b-llamacpp-q4.json
```

## Rollout phases

### Phase 1: Backend switch

- Them `llama-cpp-python`.
- Them backend abstraction.
- Chay local/Minikube voi GGUF Q4_K_M.
- Giu Transformers backend de rollback.

Done khi:

- `/health` tra backend/model/replica.
- `/chat` tra loi khong co `<think>`.
- Load test concurrency 4 pass.

### Phase 2: ARM image

- Build/push `linux/arm64`.
- Deploy len `m7g.xlarge`.
- Verify pod pull dung image ARM64.

Done khi:

- Ray head/worker Ready.
- Chat UI OK.
- Load test co p95 on dinh.

### Phase 3: Resource tuning

- Thu `2 CPU/3Gi`, `3 CPU/4Gi`, `4 CPU/5Gi`.
- Chot cost/perf.
- Update Terraform defaults.

### Phase 4: Production hardening

- Pin GGUF repo/file/checksum.
- Add Prometheus metrics.
- Add readiness endpoint that waits model loaded.
- Add request timeout.
- Add streaming SSE neu can UX tot hon.

## Rủi ro

| Rui ro | Giam thieu |
| --- | --- |
| Build ARM64 tren x86 qua lau | Build native tren EC2 Graviton tam thoi |
| GGUF repo khong tin cay | Pin repo/file/checksum |
| Qwen3 van sinh `<think>` | `enable_thinking=false`, `/no_think`, strip fallback |
| CPU oversubscription | `max_ongoing_requests=1`, `LLAMA_N_THREADS=MODEL_NUM_CPUS` |
| Scale cham do moi replica load model | Preload GGUF vao image, imagePullPolicy IfNotPresent |

## Chot

Huong toi uu that:

```text
Qwen3-0.6B GGUF Q4_K_M
llama.cpp backend
Ray Serve autoscale
KubeRay on EKS
m7g.xlarge for cheap dev
m7g.2xlarge for stable load test
```

