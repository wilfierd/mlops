# LLM RAG Chat on Ray + Kubernetes

Ứng dụng hiện tại là Document Q&A/RAG chatbot chạy trên EKS:

- Ray Serve/KubeRay chạy API RAG + ONNX embedder trên head node.
- vLLM chạy LLM 7B AWQ trên GPU node bằng image upstream `vllm/vllm-openai`.
- Qdrant lưu vector database trên EBS persistent volume.
- ECR chỉ chứa app image nhẹ: FastAPI/Ray Serve + embedder ONNX. Không build lại image LLM.

## Architecture

```text
User
  |
  | kubectl port-forward svc/llm-chat-serve-svc :8000
  v
+------------------------- EKS ephemeral stack -------------------------+
| Namespace: llm-chat                                                   |
|                                                                       |
|  m6i.large head node                                                  |
|  +----------------------+       +-------------------------------+     |
|  | RayService llm-chat  | ----> | Qdrant StatefulSet            |     |
|  | - RagApi             |       | PVC qdrant-data-pvc           |     |
|  | - Embedder ONNX INT8 |       +-------------------------------+     |
|  +----------+-----------+                                             |
|             | HTTP OpenAI-compatible call                             |
|             v                                                         |
|  g4dn.xlarge GPU node                                                 |
|  +----------------------+                                             |
|  | vllm-openai          |                                             |
|  | Qwen2.5-7B AWQ       |                                             |
|  | PVC llm-cache-pvc    |                                             |
|  +----------------------+                                             |
+------------------------------------------------------------------------+
              |
              | binds existing EBS volumes / pulls app image
              v
+----------------------- persistent stack ------------------------------+
| VPC, ECR app repo, S3 data bucket, EBS qdrant, EBS LLM cache, OIDC     |
+------------------------------------------------------------------------+
```

## Current Flow

```text
1. make persistent-apply       # one-time, giữ ECR/S3/EBS/cache
2. make cluster-up             # dựng EKS + node groups + PV/PVC
3. make push                   # build/push Dockerfile.app vào ECR
4. make qdrant-up              # Qdrant + documents collection
5. make vllm-up                # pull vllm image + cache model vào EBS
6. make rag-up                 # RayService llm-chat: RagApi + Embedder
7. make rag-pf                 # localhost:8000
```

Sau khi xong lab:

```bash
cd infra
make cluster-down
```

`cluster-down` chỉ destroy ephemeral stack. ECR, S3, EBS Qdrant, EBS model cache vẫn nằm trong persistent stack nên lần sau không phải build/download lại từ đầu.

## Important Files

| Path | Purpose |
| --- | --- |
| `Dockerfile.app` | Build app image + export embedder ONNX INT8. |
| `app/rag_server.py` | Ray Serve app: `/healthz`, `/embed`, RAG API surface. |
| `app/embedder.py` | ONNX Runtime embedder wrapper. |
| `k8s/rayservice.yaml` | Single RayService `llm-chat`; no parallel `llm-chat-rag`. |
| `k8s/qdrant.yaml` | Qdrant StatefulSet bound to persistent EBS. |
| `k8s/vllm-server.yaml` | vLLM StatefulSet using upstream vLLM image. |
| `infra/environments/dev/persistent/` | Long-lived infra. Do not destroy daily. |
| `infra/environments/dev/ephemeral/` | EKS/node groups/PVs. Safe daily destroy/apply. |
| `docs/rag-technical-design.md` | Detailed architecture plan and cost/perf reasoning. |

## Smoke Commands

```bash
cd infra
make cluster-up
make push
make qdrant-up
make vllm-up
make rag-up
make rag-pf
```

In another shell:

```bash
curl -s http://127.0.0.1:8000/healthz | jq
curl -s http://127.0.0.1:8000/embed \
  -H 'content-type: application/json' \
  -d '{"texts":["xin chao"],"mode":"query"}' | jq
```

## Cost Posture

Default is lab/cost-first:

- `persistent`: always-on storage only, roughly a few USD/month.
- `ephemeral`: EKS + `m6i.large` head + `g4dn.xlarge` spot GPU while running.
- NAT is disabled by default in persistent network config to avoid fixed NAT cost; app access is via port-forward, not public LoadBalancer.

For stable demos, use on-demand GPU or the stable profile described in `docs/rag-technical-design.md`.
