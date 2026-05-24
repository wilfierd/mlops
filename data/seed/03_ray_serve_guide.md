# Ray Serve — Hướng Dẫn Triển Khai ML Service

## 1. Ray Serve là gì?

Ray Serve là framework serving ML model tích hợp trong hệ sinh thái Ray. Điểm mạnh:
- **Deployment composition**: kết hợp nhiều model thành pipeline bằng `DeploymentHandle`
- **Autoscaling**: tự động scale replicas theo load
- **Batching**: tự động gộp request để tăng throughput GPU
- **Framework-agnostic**: hỗ trợ PyTorch, TensorFlow, ONNX, scikit-learn, bất kỳ Python code nào

## 2. Khái Niệm Cơ Bản

### Deployment

`@serve.deployment` là đơn vị triển khai cơ bản trong Ray Serve — tương đương một microservice.

```python
from ray import serve

@serve.deployment(num_replicas=2, ray_actor_options={"num_cpus": 1.0})
class MyModel:
    def __init__(self):
        self.model = load_model()

    def predict(self, text: str) -> str:
        return self.model.infer(text)
```

### Ingress

Deployment có decorator `@serve.ingress(app)` nhận HTTP request trực tiếp:

```python
from fastapi import FastAPI

api = FastAPI()

@serve.deployment
@serve.ingress(api)
class APIGateway:
    def __init__(self, model: DeploymentHandle):
        self.model = model

    @api.post("/predict")
    async def predict(self, request: PredictRequest):
        result = await self.model.predict.remote(request.text)
        return {"result": result}
```

## 3. Deployment Handle

`DeploymentHandle` cho phép gọi deployment khác async:

```python
# Gọi async (non-blocking, trả về ObjectRef)
result_ref = self.model.predict.remote(text)
result = await result_ref

# Với timeout
import asyncio
result = await asyncio.wait_for(self.model.predict.remote(text), timeout=5.0)
```

Từ Ray 2.x, `serve.get_deployment_handle()` có thể lấy handle của deployment đang chạy:

```python
handle = serve.get_deployment_handle("MyModel", app_name="my-app")
```

## 4. Binding và Application

Kết hợp các deployment thành một application bằng `.bind()`:

```python
# Truyền EmbedderHandle vào RagApi constructor
rag_app = RagApi.bind(Embedder.bind())
```

`serve.run(rag_app)` khởi động application. Với Ray Serve trên Kubernetes, dùng RayService CRD thay vì `serve.run()`.

## 5. RayService trên Kubernetes (KubeRay)

KubeRay operator quản lý vòng đời Ray cluster trên Kubernetes. RayService CRD:

```yaml
apiVersion: ray.io/v1
kind: RayService
metadata:
  name: llm-chat
spec:
  serveConfigV2: |
    applications:
    - name: llm-chat
      import_path: app.rag_server:rag_app
      route_prefix: /
      deployments:
      - name: RagApi
        num_replicas: 1
        ray_actor_options:
          num_cpus: 0.2
      - name: Embedder
        num_replicas: 1
        ray_actor_options:
          num_cpus: 0.5
  rayClusterConfig:
    rayVersion: "2.55.1"
    headGroupSpec:
      ...
```

KubeRay tự động:
- Khởi động Ray head pod
- Apply Serve config sau khi head pod Ready
- Rolling update khi spec thay đổi
- Phơi service trên port 8000

## 6. Metrics và Monitoring

Ray Serve expose metrics Prometheus tại port 8080 (`/metrics`):

- `ray_serve_replica_processing_queries`: số request đang xử lý
- `ray_serve_deployment_error_count`: số lỗi theo deployment
- `ray_serve_http_request_latency_ms`: latency HTTP

Thêm custom metrics bằng `ray.util.metrics`:

```python
from ray.util.metrics import Counter, Histogram, Gauge

# Phải khởi tạo trong actor __init__ để đăng ký đúng
class MyActor:
    def __init__(self):
        self.counter = Counter("my_counter", tag_keys=("status",))
        self.latency = Histogram("my_latency_ms", boundaries=[10, 100, 1000])

    def process(self):
        t0 = time.monotonic()
        # ... xử lý
        self.latency.observe((time.monotonic() - t0) * 1000)
        self.counter.inc(tags={"status": "ok"})
```

## 7. Autoscaling

```python
@serve.deployment(
    autoscaling_config={
        "min_replicas": 1,
        "max_replicas": 4,
        "target_ongoing_requests": 8,  # scale up khi trung bình > 8 req/replica
        "upscale_delay_s": 30,
        "downscale_delay_s": 300,
    }
)
class ScalableModel:
    ...
```

Ray Serve autoscaling dựa trên `target_ongoing_requests`: nếu trung bình số request đang xử lý vượt ngưỡng, scale up thêm replica.

## 8. max_ongoing_requests vs num_replicas

| Tham số | Ý nghĩa |
|---------|---------|
| `num_replicas` | Số actor chạy song song |
| `max_ongoing_requests` | Số request tối đa mỗi replica xử lý đồng thời |
| `max_queued_requests` | Số request tối đa xếp hàng trước khi từ chối (429) |

Với model ONNX CPU-bound: dùng `max_ongoing_requests=1–4` vì ONNX không parallel. Với FastAPI async handler: có thể dùng `max_ongoing_requests=32+`.

## 9. Deployment Update

Khi push image mới hoặc thay đổi Serve config:

1. KubeRay so sánh spec cũ và mới
2. Nếu Serve config thay đổi: Ray gọi `serve.deploy()` nội bộ
3. Nếu image thay đổi: KubeRay tạo RayCluster mới (zero-downtime với `serviceUnhealthySecondThreshold`)

**Healthy threshold** trong RayService:
- `serviceUnhealthySecondThreshold: 900s` — cho phép slow rolling update
- `deploymentUnhealthySecondThreshold: 300s` — timeout cho mỗi deployment

## 10. Debug và Troubleshooting

```bash
# Xem logs Ray head pod
kubectl logs -n llm-chat -l ray.io/node-type=head -c ray-head --tail=100

# Port-forward Ray dashboard
kubectl port-forward -n llm-chat svc/llm-chat-head-svc 8265:8265
# Mở http://localhost:8265

# Kiểm tra Serve status
ray status  # từ trong pod
python -c "from ray import serve; import ray; ray.init(); print(serve.status())"
```

Ray Dashboard tại port 8265 hiển thị:
- Trạng thái từng deployment (HEALTHY / UNHEALTHY / UPDATING)
- Số replica và request đang xử lý
- Logs từng actor
