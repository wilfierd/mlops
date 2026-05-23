# Runbook — RAG Lab

This runbook matches the current split stack:

- `infra/environments/dev/persistent/`: long-lived VPC/ECR/S3/EBS/OIDC.
- `infra/environments/dev/ephemeral/`: EKS/node groups/addons/PV bindings.
- K8s manifests: Qdrant, vLLM, RayService RAG app.

## Start A Lab Session

```bash
cd infra
make cluster-up
make push
make qdrant-up
make vllm-up
make rag-up
make rag-pf
```

Smoke:

```bash
curl -s http://127.0.0.1:8000/healthz | jq
curl -s http://127.0.0.1:8000/embed \
  -H 'content-type: application/json' \
  -d '{"texts":["xin chao"],"mode":"query"}' | jq
```

## Stop A Lab Session

```bash
cd infra
make cluster-down
```

This destroys only the ephemeral EKS stack. ECR images, S3 data, Qdrant EBS,
and LLM cache EBS are retained by the persistent stack.

## Debug Commands

```bash
make cluster-status
make qdrant-status
make vllm-logs
make rag-logs
kubectl -n llm-chat get rayservice,pods
```

Direct port-forwards:

```bash
make rag-pf       # Ray Serve RAG API on localhost:8000
make qdrant-pf    # Qdrant on localhost:6333
make vllm-pf      # vLLM OpenAI API on localhost:8000
```

## Rules

- Do not use the old flat `infra/environments/dev` Terraform root.
- Do not destroy `persistent/` in daily workflow.
- Do not build the LLM image locally; use upstream `vllm/vllm-openai`.
- Use `Dockerfile.app` only for the app/Ray/embedder image.
