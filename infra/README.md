# Infra

The dev environment is split into two Terraform stacks. This is intentional:

```text
infra/environments/dev/persistent/   # create once, keep
infra/environments/dev/ephemeral/    # create/destroy per lab session
```

## What To Run

```bash
cd infra

# One-time bootstrap
make persistent-init
make persistent-apply

# Daily lab session
make cluster-up
make push
make qdrant-up
make vllm-up
make rag-up
make rag-pf

# Save money after the session
make cluster-down
```

## Stack Ownership

| Stack | Owns | Destroy daily? |
| --- | --- | --- |
| `persistent` | VPC, ECR app repo, S3 data bucket, EBS Qdrant, EBS LLM cache, optional GitHub OIDC | No |
| `ephemeral` | EKS, head MNG, GPU MNG, NVIDIA device plugin, namespace, PV/PVC bindings | Yes |
| K8s manifests | Qdrant, vLLM, RayService app | Delete/reapply as needed |

`make cluster-down` destroys only the ephemeral stack. It does not delete ECR images, S3 files, Qdrant data, or the LLM cache volume.

## Runtime Split

```text
Ray/KubeRay:
  - API/RAG handler
  - ONNX INT8 embedder

Qdrant:
  - Vector storage
  - Persistent EBS volume

vLLM:
  - GPU LLM inference
  - Upstream vllm-openai image
  - Persistent EBS HF cache
```

The app image is built from `Dockerfile.app` and pushed to the persistent ECR repo. The LLM server image is not built locally; Kubernetes pulls the upstream vLLM image.

## Useful Commands

```bash
make cluster-status
make cluster-output
make qdrant-status
make vllm-logs
make rag-logs
```

Port forwards:

```bash
make rag-pf       # localhost:8000 -> Ray Serve API
make qdrant-pf    # localhost:6333 -> Qdrant
make vllm-pf      # localhost:8000 -> vLLM direct debug
```

Do not run bare `terraform destroy` from `infra/environments/dev/persistent/` unless you intentionally want to remove retained data and have first removed `prevent_destroy` guards.
