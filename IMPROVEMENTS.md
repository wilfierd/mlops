# Review & Improvements — CPU LLM Chat trên Ray Serve + KubeRay

Tài liệu này đánh giá hiện trạng dự án so với yêu cầu và liệt kê các cải thiện theo mức độ ưu tiên.

## 1. Bảng đối chiếu yêu cầu

| Yêu cầu | Hiện trạng | Đánh giá |
| --- | --- | --- |
| Chat với LLM tự host trên CPU | `app/server.py` dùng `AutoModelForCausalLM` + `torch.float32` với SmolLM2-135M | Đạt nhưng chậm, fp32 trên CPU lãng phí |
| Host bằng Ray trên K8s | `k8s/rayservice.yaml` (KubeRay `RayService` v1) | Đạt |
| Scale theo concurrent request | `autoscaling_config.target_ongoing_requests=1`, `min_replicas=1..max=4`, worker group autoscale | Đạt về cấu hình, nhưng tham số chưa nhất quán với cách `_generate` chạy |
| Chat được với model | UI HTML inline + `POST /chat` + `/health` | Đạt |
| Performance test | `scripts/load_test.py` (httpx async, p50/p95) | Đạt mức cơ bản, thiếu p99/throughput/scale timeline |
| Review + ghi md | — | File này |

Kết luận tổng quan: hướng đi đúng, đủ để **demo**. Để chạy thật cần các cải thiện bên dưới — quan trọng nhất là (P0) hiệu năng inference, (P0) batching/concurrency model, và (P0) chất lượng load test.

## 2. Vấn đề và đề xuất

### P0 — Hiệu năng inference CPU

**2.1 `torch_dtype=torch.float32`**
- `app/server.py:298` ép fp32. Trên CPU hiện đại (AVX-512, AMX, Apple Silicon) nên dùng `bfloat16` cho mô hình ≤3B; với mô hình lớn hơn nên quantize int8/int4.
- Đề xuất:
  - Thêm env `MODEL_DTYPE` (`float32|bfloat16|float16`) rồi map qua `torch.dtype`.
  - Hoặc dùng [`optimum-intel`](https://huggingface.co/docs/optimum/intel/index) với `OVModelForCausalLM` (OpenVINO) — thường 2–4× nhanh hơn Transformers thuần trên CPU x86.
  - Đối với mô hình ≥1B nên chuyển hẳn sang `llama.cpp` (GGUF Q4_K_M/Q5_K_M) qua `llama-cpp-python`, vẫn bọc trong Ray Serve deployment.

**2.2 Không có dynamic batching**
- `max_ongoing_requests=4` nhưng `_generate` chạy nối tiếp qua `asyncio.to_thread` → request 2,3,4 phải chờ request 1 generate xong. Hiệu năng thực = 1 request/replica tại một thời điểm.
- Đề xuất:
  - Nếu giữ Transformers: bật `@serve.batch(max_batch_size=4, batch_wait_timeout_s=0.1)` cho một hàm `_batched_generate`, pad input cùng độ dài, sinh đồng thời.
  - Hoặc đặt `max_ongoing_requests=1` để buộc Serve queue rồi scale out — nhất quán với `target_ongoing_requests=1`.

**2.3 Thiếu `attention_mask`**
- `app/server.py:353` tokenize không trả `attention_mask` rồi `pad_token = eos_token` → khi prompt có pad, mask không đúng → chất lượng output kém, có warning.
- Đề xuất: truyền `attention_mask=inputs["attention_mask"]` vào `model.generate(...)`.

**2.4 Không streaming**
- UX trên CPU đặc biệt tệ vì TTFT cao. Hiện trả về full text sau khi `generate` xong.
- Đề xuất:
  - Dùng `TextIteratorStreamer` của Transformers + endpoint SSE (`StreamingResponse(media_type="text/event-stream")`).
  - UI đọc stream và append từng token.

**2.5 Thread contention**
- `TORCH_NUM_THREADS=2` × mỗi replica có `num_cpus=2`. Worker pod cấp `limits.cpu=3` chỉ chạy 1 replica → OK. Nhưng nếu `max_ongoing_requests>1` và có batching, có thể nâng `TORCH_NUM_THREADS` lên ngang `num_cpus`.

### P0 — Cold start & model loading

**2.6 `HF_HOME=/tmp/huggingface` trên `emptyDir`**
- Mỗi pod restart phải tải lại model từ Hugging Face → cold start hàng phút, autoscale chậm.
- Đề xuất, chọn 1:
  - Bake model vào image: build với `--build-arg PRELOAD_MODEL=true`. Image nặng hơn nhưng pod start nhanh.
  - Dùng PVC `ReadOnlyMany` share giữa các pod (NFS, S3CSI, hoặc một `Job` init prefetch vào ReadWriteOnce PVC rồi mount).
  - Dùng `initContainer` tải model trước, sau đó mount vào main container.

**2.7 Health/readiness probe**
- Manifest chỉ dựa vào KubeRay tự thêm health. Nên khai báo `readinessProbe` HTTP `/health` trên container head với `initialDelaySeconds` đủ lớn (model load).
- `serviceUnhealthySecondThreshold: 900` rất dài — có thể vì model load lâu; sau khi bake model thì giảm xuống 300.

### P1 — Autoscaling đúng nghĩa

**2.8 Worker pod chỉ chứa 1 replica**
- Worker `limits.cpu=3`, mỗi replica `num_cpus=2` → 1 replica/pod. Khi scale từ 1→4 replicas phải tạo 3 pod mới → mỗi pod tải model lại → autoscale lag rất lớn.
- Đề xuất:
  - Tăng `limits.cpu` của worker (vd `8`, `num_cpus=2` thì 4 replica/pod) để tránh tạo pod khi scale.
  - Hoặc giảm `num_cpus` xuống `1` và đo lại.

**2.9 KubeRay worker group**
- `replicas: 1` ngoài `minReplicas`/`maxReplicas` không cần thiết khi `enableInTreeAutoscaling: true` — gỡ field `replicas` để Ray autoscaler kiểm soát hoàn toàn.

**2.10 Head pod**
- `num-cpus: "0"` đúng (head không chạy actor). Có thể giảm `requests.cpu` xuống `500m` để tiết kiệm.

### P1 — Performance test mạnh hơn

`scripts/load_test.py` hiện chỉ in p50/p95 và không lưu kết quả. Cần nâng cấp:

- Đo thêm: p90, p99, **throughput (RPS, tokens/s)**, **time-to-first-token** (khi có streaming), error rate, phân phối latency theo replica.
- Có **warmup** phase (vd 5 request bỏ kết quả) tránh cold-start bias.
- Có **scale timeline**: poll `kubectl -n llm-chat get pods -o json` (hoặc Ray Serve `/api/serve/applications/`) song song, log số replica theo thời gian, tính thời gian scale-up.
- **Workload pattern** tham số hoá: hằng số (constant concurrency), bậc thang (ramp), burst.
- **Output**: ghi JSON/CSV vào `reports/<timestamp>.json` + một `report.md` tóm tắt; cho phép so sánh hai run (trước/sau cải thiện).
- Thử nghiệm matrix cần chạy:
  - C=1, N=20 → baseline latency 1 replica.
  - C=4, N=40 → kiểm tra Serve queue + scale-up.
  - C=8, N=80 → kiểm tra max_replicas + worker pod autoscale.
  - C=8 ramp 60s → đo scale-up lag.

### P1 — Observability

- Ray Serve có sẵn metrics Prometheus tại `/api/serve/metrics` (Ray ≥2.55). Document cách scrape (ServiceMonitor) và một dashboard Grafana mẫu (latency p50/p95, replica count, ongoing requests).
- Log có cấu trúc: log JSON với `request_id`, `replica`, `model`, `prompt_tokens`, `completion_tokens`, `latency_ms`.
- Thêm endpoint `/metrics` cho ứng dụng (vd `prometheus-fastapi-instrumentator`).

### P2 — Bảo mật & vận hành

- Auth: ít nhất bearer token qua header, hoặc đặt sau API gateway/ingress có authn.
- Rate limit: nginx ingress annotation hoặc `slowapi` cho FastAPI.
- CORS: nếu UI khác origin thì cần `CORSMiddleware`.
- Validate tổng prompt token sau `apply_chat_template` ≤ `max_input_tokens`, từ chối sớm thay vì truncate.
- `terminationGracePeriodSeconds: 60` để cho phép request đang generate hoàn tất khi rolling update.
- `PodDisruptionBudget` `minAvailable: 1` cho `min_replicas=1`.

### P2 — Code & cấu trúc

- `app/server.py` ~390 dòng đang gộp 3 thứ: pydantic schema, HTML UI, deployment. Tách:
  - `app/schemas.py` (Pydantic).
  - `app/ui.py` hoặc đặt `index.html` static.
  - `app/server.py` chỉ giữ Ray Serve deployment.
- Tách hàm `_load_model()` tách rời để test/unit benchmark được.
- Thêm unit test tối thiểu cho `_build_prompt` (template apply, fallback) — dễ hồi quy.

### P2 — Dockerfile

- Thêm `.dockerignore` (loại `.venv`, `reports/`, `__pycache__`, `.git`).
- Multi-stage build: stage 1 tải model + cache HF; stage 2 copy `~/.cache/huggingface` vào image cuối → image nhỏ hơn so với cài torch/transformers trong stage cuối.
- Pin `pip` index hash bằng `requirements.txt` đã có; có thể bổ sung `--require-hashes` cho supply chain.

### P3 — README

- Bổ sung mục "Benchmark thực tế" với bảng kết quả load test sau cải thiện (P50/P95/P99, RPS, tokens/s, scale-up time).
- Mục "Production readiness checklist" liệt kê các điểm P0/P1 ở trên.
- Ghi rõ giới hạn: model 135M chỉ dùng để demo path, không phải để đo chất lượng câu trả lời.

## 3. Đề xuất lộ trình triển khai

Thứ tự áp dụng để có ROI cao nhất:

1. **2.3** thêm `attention_mask` (5 phút, sửa bug ngầm).
2. **2.6** bake model vào image (đổi 1 dòng build arg, giảm cold start vài chục giây).
3. **2.1** chuyển sang `bfloat16` rồi đo lại — kỳ vọng 1.5–2× nhanh.
4. **2.2** bật `@serve.batch` HOẶC chốt `max_ongoing_requests=1` — đảm bảo concurrency model nhất quán với cấu hình autoscale.
5. Nâng cấp `scripts/load_test.py` theo mục **2.11** + chạy benchmark, ghi kết quả vào `reports/`.
6. **2.4** streaming SSE — cải thiện UX rõ rệt.
7. **2.8** tăng CPU worker pod để fit nhiều replica/pod → autoscale mượt.
8. Observability (Prometheus + dashboard).
9. Phần bảo mật & vận hành (P2).

## 4. Bộ chỉ số cần đạt sau cải thiện (gợi ý baseline)

Trên máy 8 vCPU, mô hình SmolLM2-135M:

| Chỉ số | Hiện tại (ước lượng) | Mục tiêu |
| --- | --- | --- |
| Latency p50 (1 user, 64 tokens) | 2–4s | < 1.5s với bfloat16 |
| TTFT (streaming) | n/a | < 400ms |
| Throughput (4 replica, batched) | ~1 req/s | ≥ 4 req/s |
| Scale-up 1→4 replicas (model đã bake) | > 90s | < 30s |
| Cold start pod đầu tiên | > 60s | < 20s |

## 5. Phụ lục: ví dụ patch ngắn

### 5.1 Thêm `attention_mask` và `bfloat16`

```python
self.model = AutoModelForCausalLM.from_pretrained(
    self.model_id,
    torch_dtype=torch.bfloat16 if os.getenv("MODEL_DTYPE", "bfloat16") == "bfloat16" else torch.float32,
)
...
inputs = self.tokenizer(prompt, return_tensors="pt", truncation=True, max_length=self.max_input_tokens)
generation_kwargs["attention_mask"] = inputs["attention_mask"]
```

### 5.2 Dynamic batching

```python
@serve.batch(max_batch_size=4, batch_wait_timeout_s=0.1)
async def _batched_generate(self, prompts: list[str]) -> list[str]:
    inputs = self.tokenizer(prompts, return_tensors="pt", padding=True, truncation=True,
                            max_length=self.max_input_tokens)
    with torch.inference_mode():
        out = self.model.generate(**inputs, max_new_tokens=self.default_max_new_tokens,
                                  pad_token_id=self.tokenizer.pad_token_id)
    return [self.tokenizer.decode(o[inputs["input_ids"].shape[-1]:], skip_special_tokens=True).strip()
            for o in out]
```

### 5.3 SSE streaming endpoint

```python
from transformers import TextIteratorStreamer
from fastapi.responses import StreamingResponse
from threading import Thread

@api.post("/chat/stream")
async def chat_stream(self, request: ChatRequest):
    streamer = TextIteratorStreamer(self.tokenizer, skip_prompt=True, skip_special_tokens=True)
    inputs = self.tokenizer(self._build_prompt(request.messages), return_tensors="pt")
    Thread(target=self.model.generate, kwargs={**inputs, "streamer": streamer,
                                               "max_new_tokens": request.max_new_tokens or self.default_max_new_tokens}).start()
    async def gen():
        for token in streamer:
            yield f"data: {token}\n\n"
        yield "data: [DONE]\n\n"
    return StreamingResponse(gen(), media_type="text/event-stream")
```
