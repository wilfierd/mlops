# CPU LLM Chat on Ray Serve + Kubernetes

Ung dung nay host mot LLM tu quan ly tren CPU bang Ray Serve, chay tren Kubernetes qua KubeRay `RayService`, va autoscale model replicas theo concurrent request.

## Thanh phan

- `app/server.py`: FastAPI + Ray Serve deployment cho UI chat va API `/chat`.
- `k8s/rayservice.yaml`: KubeRay `RayService` gom Ray cluster, Serve app, autoscaling theo `target_ongoing_requests`.
- `Dockerfile`: image CPU cho Ray Serve + Transformers.
- `scripts/load_test.py`: tao concurrent request de kiem tra autoscale.

Model mac dinh la `HuggingFaceTB/SmolLM2-135M-Instruct` de demo tren CPU. Co the doi bang bien moi truong `MODEL_ID`.

## Kien truc

```text
+-------------------------+
| User / Browser / Client |
+------------+------------+
             |
             | HTTP /chat
             v
+-------------------------+
| port-forward or Ingress |
+------------+------------+
             |
             v
+---------------------------------------------------------------+
| Kubernetes namespace: llm-chat                                |
|                                                               |
|  +-----------------------------+                              |
|  | Service: llm-chat-serve-svc |                              |
|  | port 8000                   |                              |
|  +--------------+--------------+                              |
|                 |                                             |
|                 v                                             |
|  +---------------------------------------------------------+  |
|  | RayService: llm-chat                                   |  |
|  |                                                         |  |
|  |  +-----------------------+                              |  |
|  |  | Ray Head Pod          |                              |  |
|  |  | - Serve HTTP Proxy    |                              |  |
|  |  | - Ray GCS/Dashboard   |                              |  |
|  |  +-----------+-----------+                              |  |
|  |              | routes requests / schedules actors        |  |
|  |              v                                           |  |
|  |  +---------------------------------------------------+  |  |
|  |  | Ray Worker Pods CPU                              |  |  |
|  |  |                                                   |  |  |
|  |  |  +------------------+  +------------------+       |  |  |
|  |  |  | Serve Replica 1  |  | Serve Replica 2  | ...   |  |  |
|  |  |  | FastAPI endpoint |  | FastAPI endpoint |       |  |  |
|  |  |  | Transformers LLM |  | Transformers LLM |       |  |  |
|  |  |  | CPU inference    |  | CPU inference    |       |  |  |
|  |  |  +------------------+  +------------------+       |  |  |
|  |  +---------------------------------------------------+  |  |
|  +---------------------------------------------------------+  |
|                                                               |
|  KubeRay Operator watches RayService and creates/updates pods. |
+---------------------------------------------------------------+
```

Vai tro tung thanh phan:

- `RayService`: custom resource cua KubeRay, khai bao Ray cluster va Ray Serve app trong mot manifest.
- `Ray Head Pod`: quan ly Ray cluster, dashboard, GCS va Serve HTTP proxy.
- `Ray Worker Pods`: noi chay model replicas tren CPU.
- `Serve Replica`: mot actor Ray load tokenizer/model va xu ly request `/chat`.
- `K8S Service`: endpoint Kubernetes expose Ray Serve HTTP proxy.

## Flow chat request

```text
1. User / Browser
   |
   | POST /chat
   | body: {messages, max_new_tokens, temperature, top_p}
   v
2. Kubernetes Service: llm-chat-serve-svc:8000
   |
   | forward HTTP request
   v
3. Ray Serve HTTP Proxy
   |
   | route to an available ChatModel replica
   v
4. ChatModel Serve Replica
   |
   | validate request
   | build prompt from chat history
   | call tokenizer
   v
5. CPU LLM
   |
   | model.generate()
   v
6. ChatModel Serve Replica
   |
   | decode generated tokens
   | response: {answer, model, replica}
   v
7. User / Browser renders answer
```

Flow trong code:

- UI va API nam trong `app/server.py`.
- Endpoint `POST /chat` nhan `messages`, `max_new_tokens`, `temperature`, `top_p`.
- Replica goi `AutoTokenizer` va `AutoModelForCausalLM` cua Transformers.
- Sinh text bang `model.generate()` tren CPU, tra ve `answer` kem `model` va `replica` de de debug request da vao pod nao.

## Flow autoscaling

```text
Concurrent requests increase
          |
          v
Ray Serve proxy sends requests to deployment: ChatModel
          |
          v
+--------------------------------------------------+
| Is ongoing_requests_per_replica                  |
| greater than target_ongoing_requests?            |
+----------------------+---------------------------+
                       |
             No        |        Yes
             |         |         |
             v         |         v
 Keep current replica  |  Ray Serve autoscaler
 count                 |  adds model replicas
                       |  up to max_replicas
                       |         |
                       |         v
                       | +--------------------------+
                       | | Does Ray cluster have    |
                       | | enough free CPU?         |
                       | +------------+-------------+
                       |              |
                       |    Yes       |       No
                       |     |        |        |
                       |     v        |        v
                       | Schedule new | Ray autoscaler asks
                       | replica on   | KubeRay for more
                       | existing pod | worker pods
                       |     |        |        |
                       |     |        |        v
                       |     |        | KubeRay creates new
                       |     |        | Ray worker pod
                       |     |        |        |
                       |     |        |        v
                       |     |        | New replica loads
                       |     |        | model on CPU
                       |     |        |
                       +-----+--------+
                             |
                             v
                 Requests are spread across replicas
```

Cau hinh autoscale hien tai trong `k8s/rayservice.yaml`:

| Lop scale | Cau hinh | Y nghia |
| --- | --- | --- |
| Ray Serve replica | `target_ongoing_requests: 1` | Neu trung binh moi replica co hon 1 request dang xu ly, Serve scale out. |
| Ray Serve replica | `max_ongoing_requests: 1` | Mot replica xu ly 1 request mot luc — phu hop khi chua bat dynamic batching tren CPU. |
| Ray Serve replica | `min_replicas: 1`, `max_replicas: 4` | Luon co it nhat 1 model replica, toi da 4. |
| Ray actor resources | `num_cpus: 2` | Moi model replica can 2 CPU logical trong Ray. |
| Ray worker pods | `minReplicas: 1`, `maxReplicas: 4` | KubeRay tang worker pod khi cluster thieu CPU cho replica moi. |
| Model dtype | `MODEL_DTYPE=bfloat16` | Suy luan nhanh hon ~1.5–2x so voi float32 tren CPU AVX-512/AMX. |

Dieu quan trong: Serve scale theo request dang xu ly, con KubeRay scale worker pod khi Ray cluster khong con du CPU de schedule replica moi.

## Chay local

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
serve run app.server:chat_app
```

Mo UI tai `http://127.0.0.1:8000`.

Goi API:

```bash
curl -s http://127.0.0.1:8000/chat \
  -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"Viet 3 y tuong MLOps ngan gon"}]}' | jq
```

## Build image thu cong

```bash
docker build -t llm-chat-ray:0.1.0 .
```

Neu muon bake model vao image de pod khong phai download luc start:

```bash
docker build \
  --build-arg PRELOAD_MODEL=true \
  --build-arg MODEL_ID=HuggingFaceTB/SmolLM2-135M-Instruct \
  -t llm-chat-ray:0.1.0 .
```

Push image len registry ma cluster truy cap duoc, hoac load image vao Minikube/kind neu deploy K8S local.

## Deploy tren Kubernetes local

Local deploy mac dinh dung **Minikube chay tren Docker driver**. Docker o day chi de tao node Kubernetes local va build/load image; app van chay tren K8S bang KubeRay `RayService`.

```text
Docker daemon
  |
  +-- Minikube node container
      |
      +-- Kubernetes API
      +-- KubeRay operator
      +-- RayService
          |
          +-- Ray head pod
          +-- Ray worker pod(s)
              |
              +-- Ray Serve ChatModel replica
                  |
                  +-- Transformers LLM on CPU
```

Deploy Minikube mot lenh:

```bash
./scripts/deploy_minikube.sh
```

Script `scripts/deploy_minikube.sh` lam cac viec:

1. Kiem tra `docker`, `minikube`, `kubectl`, `helm`.
2. Start Minikube bang Docker driver neu profile chua chay.
3. Chuyen kube context sang Minikube.
4. Goi `scripts/deploy.sh` voi `LOAD_IMAGE=minikube`.

Script `scripts/deploy.sh` lam cac viec:

1. Build Docker image.
2. Load image vao Minikube/kind neu set `LOAD_IMAGE`.
3. Cai KubeRay operator bang Helm neu cluster chua co KubeRay.
4. Render manifest tam voi `IMAGE`, `MODEL_ID`, `NAMESPACE`.
5. Apply `RayService`.

Can co cac command:

```bash
docker
kubectl
helm
minikube  # neu dung Minikube
kind      # neu dung kind
```

Fedora cai Minikube:

```bash
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-latest.x86_64.rpm
sudo rpm -Uvh minikube-latest.x86_64.rpm
```

Fedora cai Helm:

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Mo chat UI sau khi deploy:

```bash
kubectl -n llm-chat port-forward svc/llm-chat-serve-svc 8000:8000
```

Mo `http://127.0.0.1:8000`.

### Deploy tu dong bang script

Neu dung Minikube Docker driver, chay:

```bash
chmod +x scripts/deploy_minikube.sh
./scripts/deploy_minikube.sh
```

Neu muon tu start cluster thu cong:

```bash
minikube start --driver=docker --cpus=6 --memory=8192
LOAD_IMAGE=minikube ./scripts/deploy.sh
```

Bien moi truong hay dung:

```bash
# Minikube
LOAD_IMAGE=minikube ./scripts/deploy.sh

# kind
LOAD_IMAGE=kind ./scripts/deploy.sh

# Doi model
LOAD_IMAGE=minikube MODEL_ID=Qwen/Qwen2.5-0.5B-Instruct ./scripts/deploy.sh

# Neu KubeRay operator da cai san
LOAD_IMAGE=minikube INSTALL_KUBERAY=false ./scripts/deploy.sh

# Mac dinh INSTALL_KUBERAY=auto:
# - neu cluster da co CRD rayservices.ray.io thi skip Helm
# - neu chua co KubeRay thi can cai helm de script install operator

# Build image kem model trong image
PRELOAD_MODEL=true ./scripts/deploy.sh

# Dung registry rieng thay vi image local trong Minikube
IMAGE=registry.example.com/mlops/llm-chat-ray:0.1.0 PUSH_IMAGE=true LOAD_IMAGE=none ./scripts/deploy.sh
```

Neu gap loi `missing command: helm`, co 2 cach:

```bash
# Cach 1: KubeRay da cai san trong cluster
INSTALL_KUBERAY=false ./scripts/deploy.sh

# Cach 2: cai Helm truoc, roi chay lai script
./scripts/deploy.sh
```

## Autoscaling

`k8s/rayservice.yaml` co hai lop scale:

- Ray Serve scale model replicas theo request dang xu ly:
  - `target_ongoing_requests: 1`
  - `max_ongoing_requests: 1` (1 request/replica/luot — chua bat batching)
  - `min_replicas: 1`
  - `max_replicas: 4`
- Ray cluster scale worker pods khi Serve can them CPU:
  - worker group `minReplicas: 1`
  - `maxReplicas: 4`
  - moi model replica dung `num_cpus: 2`

Test tai dong thoi (load_test moi co warmup, p99, throughput, replica distribution, JSON output):

```bash
mkdir -p reports
python scripts/load_test.py \
  --url http://127.0.0.1:8000/chat \
  --concurrency 8 --requests 24 --warmup 2 --max-new-tokens 64 \
  --output reports/load-$(date +%Y%m%d-%H%M%S).json

# Theo doi pod song song:
kubectl -n llm-chat get pods -w
```

## Tuy chinh nhanh

Sua env trong `k8s/rayservice.yaml`:

- `MODEL_ID`: model Hugging Face compatible causal LM.
- `MODEL_DTYPE`: `bfloat16` (mac dinh, nhanh tren CPU x86 moi) | `float32` | `float16`.
- `MAX_NEW_TOKENS`: gioi han token sinh ra mac dinh.
- `MAX_INPUT_TOKENS`: gioi han do dai prompt truoc khi truncate.
- `TORCH_NUM_THREADS`: so CPU thread moi replica dung.
- `MODEL_NUM_CPUS`: CPU Ray cap cho moi replica.
- `MAX_ONGOING_REQUESTS`: so request mot replica chap nhan dong thoi (mac dinh 1).

Model CPU lon hon se can tang memory request/limit cho worker pod.

## Cai thien

Xem `IMPROVEMENTS.md` cho review chi tiet va cac fix con lai (streaming SSE, dynamic batching, observability, security).
