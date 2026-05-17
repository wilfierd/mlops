# Production Readiness Review

Review tổng thể: kiến trúc, lựa chọn công nghệ, code, infra, và OPTIMIZATION_PLAN.md so với chuẩn production.

## TL;DR

**Đã làm rất tốt** (8/10 cho POC, 5/10 cho prod):
- Kiến trúc Ray Serve + KubeRay + EKS chuẩn cho self-host LLM CPU.
- Terraform layout chuẩn industry (`environments/` + `modules/` + official modules).
- Đã handle hết các edge case nasty: `bfloat16`, `attention_mask`, `GRPC_DNS_RESOLVER=native`, `pids-limit`, `ENABLE_THINKING=false` cho Qwen3, `kubectl_manifest` thay `kubernetes_manifest`.
- ARM Graviton (`m7g.xlarge`) → giá hợp lý cho CPU inference.
- `OPTIMIZATION_PLAN.md` là một roadmap rất thực tế.

**Còn cách prod khá xa**:
- **Inference**: Transformers Python KHÔNG phải backend CPU tốt nhất — `OPTIMIZATION_PLAN.md` chỉ ra `llama.cpp + GGUF Q4_K_M` đúng hướng nhưng **chưa implement**.
- **UX**: không streaming → user phải đợi 5-10s nhìn màn hình trắng.
- **Observability**: zero — không metrics, không log structured, không alerting.
- **Security**: API endpoint public không auth, không rate limit, không TLS.
- **Reliability**: single AZ, không PDB, emptyDir HF cache → reload model mỗi pod restart.
- **CI/CD**: không có pipeline, deploy manual.

Verdict: **đủ tốt để demo + benchmark, chưa đủ chạy prod**. Cần Phase 2-4 trong OPTIMIZATION_PLAN + thêm 4-5 mục dưới đây.

---

## 1. Review OPTIMIZATION_PLAN.md

### Điểm mạnh
- ✅ Quyết định **llama.cpp + GGUF Q4_K_M** đúng — CPU inference của LLM nhỏ chạy nhanh hơn 2-3x so với Transformers Python.
- ✅ Resource sizing thực tế (3 CPU/3Gi cho 0.6B Q4 là vừa).
- ✅ Instance lựa chọn ARM (m7g) đúng cho cost.
- ✅ Test matrix có comparative (transformers vs llamacpp).
- ✅ Phase rollout giảm rủi ro.

### Điểm thiếu / cần bổ sung

| Mục | Cần thêm |
|---|---|
| **Backend abstraction** | OK ý tưởng nhưng cần spec rõ interface (`generate(messages, **kwargs) -> str` async). Có cần streaming interface `agenerate_stream` không? |
| **Streaming SSE** | Plan không nhắc. Đây là UX killer cho CPU model — bắt buộc cho prod. |
| **Dynamic batching** | `@serve.batch` cho phép pack 2-4 request đồng thời với padding. llama.cpp cũng support `parallel slots`. Plan nên mention. |
| **KV cache reuse** | llama.cpp có `cache_prompt=True` để cache prefix tokens. Multi-turn chat tăng tốc 5-10x câu sau. |
| **Validation step** | Phase 1 "Done khi" thiếu: latency baseline cụ thể (vd p95 < 3s) thay vì "load test concurrency 4 pass". |
| **Rollback path** | Plan nói "giu Transformers backend de rollback" nhưng không nói rollback bằng cách nào (env var? image tag?). Cần `INFERENCE_BACKEND` env switch. |
| **Image size** | llama.cpp built-in tốt nhưng `llama-cpp-python` wheel ARM build qua QEMU rất chậm (30+ phút). Plan có note nhưng chưa giải pháp cụ thể — cần GitHub Actions ARM runner hoặc EC2 Graviton tạm. |

### Đề xuất bổ sung Phase mới

**Phase 0.5 — Streaming trước khi backend switch** (1 ngày):
- Thêm `/chat/stream` endpoint với `TextIteratorStreamer` (Transformers) hoặc `iter_create_completion` (llama.cpp).
- UI fetch SSE, render incremental.
- UX cải thiện ngay 90% trước khi tối ưu inference.

**Phase 2.5 — Persistent model cache** (4h):
- Mount PVC ReadWriteMany hoặc S3-CSI vào `/tmp/huggingface`.
- Pod restart không cần re-download. Cold start giảm từ ~3 phút xuống 30s.

**Phase 5 — Observability** (1-2 ngày):
- Prometheus ServiceMonitor scrape Ray Serve `/-/metrics`.
- Grafana dashboard với panel: latency p50/p95/p99, RPS, tokens/s, replica count, queue depth.
- CloudWatch Logs forwarder (fluent-bit) cho audit.

---

## 2. Architecture review

### 2.1 Inference layer

| Thành phần | Hiện tại | Vấn đề | Đề xuất |
|---|---|---|---|
| Model | Qwen3-0.6B HF safetensors | Tốt cho POC | Plan đã chỉ Q4_K_M (Phase 1) |
| Backend | Transformers bf16 | Chậm CPU | llama.cpp (Phase 1) |
| Concurrency | `max_ongoing_requests=1` per replica | Đúng cho POC, lãng phí cho prod | Bật `@serve.batch` size 2-4 sau khi switch llama.cpp |
| Streaming | Không | UX kém | `/chat/stream` SSE |
| Generation params | Hardcode `top_p=0.8`, temperature 0.7 | OK | Tuning hằng số sau benchmark |
| Tokenizer | HF tokenizer | Đôi khi chậm hơn fast variant | OK với 0.6B |

### 2.2 Ray cluster layer

| Mục | Đánh giá |
|---|---|
| Head pod resources (2/3 CPU, 4/6 Gi) | ✅ Hợp lý sau khi fix `pthread_create` |
| Worker resources (3/4 CPU, 4/6 Gi) | ✅ 1 replica/worker pod hiện tại |
| Autoscale config | ✅ `target_ongoing_requests=1`, upscale_delay 10s |
| Worker group rayStartParams empty | ✅ Cho phép Ray auto-detect resources |
| `proxy_location: EveryNode` | ⚠️ Tạo proxy trên head + worker → mỗi worker pod có proxy actor → tốn thêm 0.1 CPU. Không cần vì traffic chỉ đến qua head. **Đổi thành `HeadOnly`**. |
| `GRPC_DNS_RESOLVER=native` | ✅ Bug đã fix |
| `HF_HOME` emptyDir | ❌ Mỗi pod restart re-download nếu image không bake. **Đổi sang PVC** hoặc luôn bake. |
| `serviceUnhealthySecondThreshold: 900` | ⚠️ Quá rộng (15 phút). Sau khi bake model, hạ về 300. |

### 2.3 K8s / Infra layer

**Đánh giá per-module:**

#### network/
- ✅ Wrap `terraform-aws-modules/vpc/aws` chuẩn.
- ✅ Subnet tags cho EKS auto-discovery (`kubernetes.io/cluster/<name>`, `role/elb`, `role/internal-elb`).
- ❌ **Single NAT GW** = SPOF + bottleneck cho image pull. Cost cut OK cho dev, prod cần multi-AZ.
- ❌ Không có VPC endpoints cho ECR/S3/Logs → traffic ra Internet qua NAT (tốn $/GB).
- ❌ Không có VPC Flow Logs → khó debug network issue.

#### ecr/
- ✅ Lifecycle policy hợp lý.
- ✅ `force_delete=true` cho destroy không kẹt.
- ✅ Image scanning enabled.
- ❌ Không có **immutable tags** → cùng tag `0.1.0` có thể bị overwrite, rủi ro rollback.
- ❌ Không có **KMS encryption** (chỉ AES256 default).

#### eks/
- ✅ Wrap `terraform-aws-modules/eks/aws v20`.
- ✅ IRSA-ready (OIDC provider).
- ✅ MNG với map type — flexible thêm spot/gpu pool.
- ❌ **API endpoint public** (`cluster_endpoint_public_access=true`) — prod cần restrict bằng `public_access_cidrs` hoặc private-only + VPN/bastion.
- ❌ Không có **EBS CSI Driver** — nếu cần PV cho HF cache là kẹt.
- ❌ Không có **AWS Load Balancer Controller** — chưa expose ngoài K8s được.
- ❌ Không có **cluster autoscaler / Karpenter** — MNG autoscale chậm hơn Karpenter ~3-5x.

#### kuberay/
- ✅ `kubectl_manifest` thay `kubernetes_manifest` — 1-phase apply.
- ✅ Helm release + namespace + manifest theo đúng thứ tự.
- ❌ Không có **readiness probe** cho ChatModel actor — load balancer route trafic về replica chưa load xong model.
- ❌ Không có **PodDisruptionBudget** — node drain có thể xoá hết replicas.
- ❌ Không có **HPA limit** ngoài Ray Serve — nếu Ray Serve scale dồn replicas, không có safety net.

### 2.4 Application code review

```python
# app/server.py:319-331
@serve.deployment(
    name="ChatModel",
    ray_actor_options={"num_cpus": _env_float("MODEL_NUM_CPUS", 2.0)},
    max_ongoing_requests=_env_int("MAX_ONGOING_REQUESTS", 1),
    autoscaling_config={...},
)
@serve.ingress(api)
class ChatModel:
    def __init__(self):
        self.model = AutoModelForCausalLM.from_pretrained(self.model_id, torch_dtype=self.dtype)
```

**Vấn đề:**
1. **All-in-one file** ~450 dòng trộn HTML, Pydantic, Ray deployment, model loading. Tách:
   - `app/schemas.py` — Pydantic models.
   - `app/ui.py` — HTML template.
   - `app/backends/__init__.py`, `app/backends/transformers_backend.py`, `app/backends/llamacpp_backend.py` — backend abstraction theo OPTIMIZATION_PLAN.
   - `app/server.py` — chỉ giữ FastAPI endpoint + Ray deployment.
2. **Không có tests**. Tối thiểu cần:
   - `tests/test_prompt.py` — `_build_prompt` đúng format chat template.
   - `tests/test_thinking_strip.py` — strip `<think>` khi enable_thinking=false.
   - `tests/test_schema.py` — Pydantic validation.
3. **Generation thực thi trong `asyncio.to_thread`** — không lock GIL nhưng vẫn block 1 thread/request. OK cho `max_ongoing_requests=1`, không phù hợp khi bật batching.
4. **Validate prompt length sau `apply_chat_template`** — hiện chỉ validate message content `max_length=8000` chars, nhưng tổng prompt sau template có thể vượt `max_input_tokens=2048` → bị truncate âm thầm.
5. **Không có request_id** trong response → không trace được request qua replica/log.

### 2.5 Docker / build

```dockerfile
FROM rayproject/ray:${RAY_VERSION}-py311-cpu  # 3GB base
RUN pip install torch CPU
RUN pip install -r requirements.txt
RUN if PRELOAD=true: download HF model
```

**Vấn đề:**
1. **Single-stage build** → image cuối ~3.5GB. Multi-stage:
   - Stage 1: install deps + bake model vào `/opt/cache`.
   - Stage 2: `FROM rayproject/ray:...` + `COPY --from=stage1 /opt/cache /opt/cache`.
   - Final image vẫn ~3.5GB (model là phần lớn) nhưng layer sạch hơn.
2. **Không có `.dockerignore`** — build context có thể chứa `.terraform/`, `reports/`, `.venv/` → upload chậm.
3. **`pip install --no-cache-dir`** OK nhưng nên thêm `--require-hashes` cho prod supply chain.
4. **Không có image label** (`org.opencontainers.image.source`, `revision`, `created`) — khó audit image trong production.
5. **ARM build** chưa wire — `IMAGE_PLATFORM` đã có trong `push_image.sh` nhưng cần documented + tested.

---

## 3. Production readiness gaps (priority-ranked)

### P0 — Must fix trước prod

| # | Item | Effort | Impact |
|---|---|---|---|
| P0.1 | **Streaming SSE** (`/chat/stream`) | 4h | UX biggest win — user thấy token chảy ra ngay |
| P0.2 | **llama.cpp + GGUF Q4_K_M backend** (OPTIMIZATION_PLAN Phase 1) | 1-2 ngày | Latency giảm 2-3x |
| P0.3 | **Auth + rate limit** trên `/chat` | 1 ngày | Endpoint public không protect = bị abuse |
| P0.4 | **HTTPS + Ingress** (ALB Controller + cert-manager) | 1 ngày | Không HTTPS = không prod |
| P0.5 | **Restrict EKS API public access** (`public_access_cidrs`) | 30 phút | Reduce attack surface |
| P0.6 | **PodDisruptionBudget** `minAvailable: 1` | 15 phút | Tránh drain xóa hết replicas |
| P0.7 | **Readiness probe** cho ChatModel | 1h | Không route traffic về replica chưa sẵn |

### P1 — Sau prod launch

| # | Item | Effort | Impact |
|---|---|---|---|
| P1.1 | **Prometheus + Grafana** + dashboard Serve | 1 ngày | Khi xảy ra incident có data |
| P1.2 | **PVC cho HF cache** (EBS CSI) | 4h | Cold start nhanh 5x |
| P1.3 | **CI/CD pipeline** GitHub Actions (build + push ECR + apply TF) | 1 ngày | Deploy reproducible |
| P1.4 | **Immutable image tags** + ArgoCD/Flux | 1-2 ngày | Rollback trivial |
| P1.5 | **VPC endpoints** cho ECR/S3/Logs | 2h | Cost down ~30% NAT traffic |
| P1.6 | **Multi-AZ workers** | 1h (chỉ đổi tfvars) | HA |
| P1.7 | **Dynamic batching** `@serve.batch` | 4h | Throughput +50-100% |
| P1.8 | **Backend abstraction + tests** | 1 ngày | Maintainability |

### P2 — Polish

| # | Item | Effort | Impact |
|---|---|---|---|
| P2.1 | **Spot instances** cho non-critical workload | 2h | Cost -70% |
| P2.2 | **Karpenter** thay MNG autoscale | 1 ngày | Scale-up nhanh 5x |
| P2.3 | **Cost dashboard** (Cost Explorer + tags) | 4h | Visibility |
| P2.4 | **Secrets Manager** integration nếu cần API key | 2h | Security |
| P2.5 | **CORS + CSP** trên FastAPI | 1h | Frontend từ origin khác |
| P2.6 | **Runbook + ADR** | 1 ngày | Onboarding team |
| P2.7 | **CloudWatch alarms** (p99 latency, error rate) | 4h | Proactive alerting |

---

## 4. Concrete changes — đề xuất implement ngay

### 4.1 Bật streaming SSE (P0.1, 4h)

```python
# app/server.py — thêm endpoint
from fastapi.responses import StreamingResponse
from threading import Thread
from transformers import TextIteratorStreamer

@api.post("/chat/stream")
async def chat_stream(self, request: ChatRequest):
    prompt = self._build_prompt(request.messages)
    inputs = self.tokenizer(prompt, return_tensors="pt", truncation=True,
                            max_length=self.max_input_tokens)
    streamer = TextIteratorStreamer(self.tokenizer, skip_prompt=True, skip_special_tokens=True)
    gen_kwargs = dict(**inputs, streamer=streamer,
                      max_new_tokens=request.max_new_tokens or self.default_max_new_tokens,
                      do_sample=request.temperature > 0,
                      temperature=request.temperature, top_p=request.top_p,
                      pad_token_id=self.tokenizer.pad_token_id)
    Thread(target=self.model.generate, kwargs=gen_kwargs, daemon=True).start()

    async def stream():
        for token in streamer:
            yield f"data: {json.dumps({'token': token})}\n\n"
        yield "data: [DONE]\n\n"

    return StreamingResponse(stream(), media_type="text/event-stream")
```

UI fetch:
```javascript
const res = await fetch("/chat/stream", {method:"POST", body: JSON.stringify({messages})});
const reader = res.body.getReader();
// loop parse SSE, append chunk to assistant message bubble
```

### 4.2 PodDisruptionBudget (P0.6, 15 phút)

Thêm vào `modules/kuberay/main.tf`:

```hcl
resource "kubernetes_manifest" "pdb_worker" {
  manifest = {
    apiVersion = "policy/v1"
    kind       = "PodDisruptionBudget"
    metadata = {
      name      = "${var.service_name}-worker-pdb"
      namespace = var.namespace
    }
    spec = {
      minAvailable = 1
      selector = {
        matchLabels = {
          "ray.io/cluster"   = var.service_name
          "ray.io/node-type" = "worker"
        }
      }
    }
  }
  depends_on = [kubectl_manifest.rayservice]
}
```

### 4.3 Readiness probe (P0.7, 1h)

Thêm vào worker container spec trong `modules/kuberay/main.tf`:

```hcl
readinessProbe = {
  httpGet = {
    path = "/health"
    port = 8000
  }
  initialDelaySeconds = 30
  periodSeconds       = 10
  failureThreshold    = 3
}
```

Và update `/health` để chỉ trả `200` khi model load xong.

### 4.4 Restrict EKS API (P0.5, 30 phút)

```hcl
# modules/eks/variables.tf
variable "public_access_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]  # dev — đổi thành office/VPN CIDRs cho prod
}

# modules/eks/main.tf — module "eks" block
cluster_endpoint_public_access_cidrs = var.public_access_cidrs
```

### 4.5 Proxy location HeadOnly (5 phút)

```hcl
# modules/kuberay/main.tf
serveConfigV2 = yamlencode({
  proxy_location = "HeadOnly"   # thay EveryNode -> tiết kiệm CPU
  ...
})
```

### 4.6 Multi-AZ workers (1h, chỉ cần khi cần HA)

```hcl
# modules/network/outputs.tf
output "worker_subnet_ids" {
  value = module.vpc.private_subnets  # cả 2 AZ thay vì slice(0,1)
}

# modules/network/main.tf
single_nat_gateway     = false
one_nat_gateway_per_az = true  # tốn thêm $33/AZ
```

### 4.7 EBS CSI + PVC cho HF cache (P1.2, 4h)

```hcl
# modules/eks/main.tf — thêm EKS addon
cluster_addons = {
  aws-ebs-csi-driver = {
    most_recent              = true
    service_account_role_arn = aws_iam_role.ebs_csi.arn
  }
  ...
}
```

Trong manifest, thay `emptyDir` bằng PVC ReadWriteOnce (mỗi pod tự cache, không share nhưng survives restart). Hoặc EFS CSI + ReadWriteMany để share giữa replicas.

### 4.8 Image immutability (P1.4, 30 phút)

```hcl
# modules/ecr/variables.tf
default = "IMMUTABLE"  # cho prod
```

CI/CD push image với tag `${git-sha}` thay vì `0.1.0`.

### 4.9 Prometheus + Grafana (P1.1, 1 ngày)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace
```

Ray Serve auto-expose `/api/serve/metrics` (Prometheus format). Thêm ServiceMonitor:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ray-serve
  namespace: llm-chat
spec:
  selector:
    matchLabels:
      ray.io/cluster: llm-chat
  endpoints:
    - port: dashboard
      path: /api/serve/metrics
      interval: 15s
```

Pre-built dashboard JSON: search "ray serve grafana dashboard" trên grafana.com.

### 4.10 CI/CD GitHub Actions (P1.3, 1 ngày)

`.github/workflows/deploy.yml`:

```yaml
on:
  push:
    branches: [main]
    paths: ['app/**', 'Dockerfile', 'requirements.txt']

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions: {id-token: write, contents: read}
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<AWS_ACCOUNT_ID>:role/gh-actions-deploy
          aws-region: us-west-2
      - uses: aws-actions/amazon-ecr-login@v2
        id: ecr
      - uses: docker/setup-buildx-action@v3
      - uses: docker/build-push-action@v5
        with:
          platforms: linux/arm64
          push: true
          build-args: |
            MODEL_ID=Qwen/Qwen3-0.6B
            PRELOAD_MODEL=true
          tags: |
            ${{ steps.ecr.outputs.registry }}/llm-chat-dev-ray:${{ github.sha }}
            ${{ steps.ecr.outputs.registry }}/llm-chat-dev-ray:latest

  terraform:
    needs: build-and-push
    runs-on: ubuntu-latest
    steps:
      - uses: hashicorp/setup-terraform@v3
      - run: |
          cd infra/environments/dev
          terraform init
          terraform apply -auto-approve -var "image_tag=${{ github.sha }}"
```

---

## 5. Architecture đề xuất sau khi áp dụng đủ cải tiến

```
                Internet
                   │
                   ▼
              ┌────────────────────┐
              │ Route 53           │ ← TLS cert ACM
              └─────────┬──────────┘
                        │
                        ▼
              ┌────────────────────┐
              │ AWS ALB Controller │ ← WAF + auth (Cognito/OIDC)
              │ Public ALB         │
              └─────────┬──────────┘
                        │
              ┌─────────▼──────────┐
              │ Ingress NetworkPolicy │
              └─────────┬──────────┘
                        │
        ┌───────────────┼────────────────┐
        ▼               ▼                ▼
   ┌──────┐        ┌──────┐         ┌──────┐
   │ Pod  │        │ Pod  │  ...    │ Pod  │
   │Serve │        │Serve │         │Serve │
   │Proxy │        │Replica         │Replica
   └──┬───┘        └───┬──┘         └───┬──┘
      │                │                │
      │ Ray RPC        │                │
      ▼                ▼                ▼
   ┌──────────────────────────────────────┐
   │ Ray Serve replicas (autoscale 1..N)  │
   │ - llama.cpp Q4_K_M                   │
   │ - SSE streaming                      │
   │ - @serve.batch size 4                │
   │ - cache_prompt for multi-turn        │
   └──────────────────┬───────────────────┘
                      │
                      ▼
              ┌────────────────────┐
              │ PVC EBS CSI gp3    │ ← HF cache persistent
              └────────────────────┘
              ┌────────────────────┐
              │ Prometheus → Grafana│
              │ CloudWatch Logs     │
              │ X-Ray traces        │
              └────────────────────┘
```

---

## 6. Đối chiếu OPTIMIZATION_PLAN.md ↔ review này

OPTIMIZATION_PLAN cover Phase 1-4 inference + image. Review này thêm:

- **Phase 0.5**: Streaming SSE trước backend switch.
- **Phase 2.5**: Persistent HF cache.
- **Phase 5**: Observability.
- **Phase 6**: Security hardening (Ingress + TLS + auth + rate limit).
- **Phase 7**: CI/CD pipeline.
- **Phase 8**: Multi-env (staging/prod tfvars + state).

Cộng các Phase này, có lộ trình ~3 tuần để đưa hệ thống tới mức "prod-ready cho internal users".

---

## 7. Đánh giá cuối

### Đã tốt cần giữ
1. Lựa chọn Ray Serve + KubeRay + EKS cho self-host LLM CPU.
2. Terraform layout chuẩn industry.
3. ARM Graviton instance.
4. Qwen3-0.6B với thinking off — model phù hợp CPU + tiếng Việt.
5. Đã fix tất cả các bug nasty trong môi trường local (pids, grpc dns, image tag, ecr force delete, etc.) — kinh nghiệm đó đáng giá khi debug prod.

### Phải fix trước khi gọi là prod
1. **Inference backend** — llama.cpp Q4 (đã có plan).
2. **Streaming** — không có không thể UX được.
3. **Security baseline** — ALB + TLS + auth + restrict EKS public.
4. **Observability** — Prometheus tối thiểu.

### Có thể trì hoãn
- Multi-AZ (chỉ cần khi SLA cao).
- Karpenter (MNG autoscale chậm hơn nhưng OK).
- Spot instance (tối ưu cost).

Tổng nhận xét: **kiến trúc đúng hướng, lựa chọn công nghệ hợp lý, quy mô refactor không lớn**. OPTIMIZATION_PLAN.md là tài liệu chất lượng, chỉ cần bổ sung phần security + observability + UX (streaming) là đầy đủ.
