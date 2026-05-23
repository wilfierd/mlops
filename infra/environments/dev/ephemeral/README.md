# `dev/ephemeral/` — destroy/recreate cluster

## Convention

| Stack | Lifecycle |
|---|---|
| `persistent/` (sibling) | Created once. Do not destroy. |
| `ephemeral/` (this dir) | **Destroy/apply freely** between dev sessions. |

Daily flow:

```bash
make cluster-up          # 12–15 min: EKS + 2 MNGs + addons + PVs bind
# ... work ...
make cluster-down        # 5 min: snapshot Qdrant → S3, then destroy
```

## What this stack creates

| Resource | Notes |
|---|---|
| EKS control plane v1.30 | $0.10/h |
| Head MNG (m6i.xlarge SPOT) | 1 node x86, Ray head + FastAPI + Embedder + Qdrant |
| GPU MNG (g6/g5.xlarge SPOT) | 0–2 nodes, AL2023_x86_64_NVIDIA AMI (driver preinstalled) |
| addons: vpc-cni, coredns, kube-proxy, **aws-ebs-csi-driver** (with IRSA) | |
| Helm: `nvidia-device-plugin` v0.14.5 | tolerates `nvidia.com/gpu` taint |
| K8s namespace `llm-chat` | |
| StorageClass `gp3-retain` | `WaitForFirstConsumer` + `Retain` |
| PV `qdrant-data-pv` → bound to EBS `vol-...` (persistent stack) | survives destroy |
| PV `llm-cache-pv` → bound to EBS `vol-...` (persistent stack) | survives destroy |
| PVC `qdrant-data-pvc`, `llm-cache-pvc` in `llm-chat` namespace | |

App workloads (RayService, Qdrant StatefulSet, vllm-openai StatefulSet) are deployed in **later phases (P2 onward)** by separate Helm/kubectl manifests — not by Terraform.

## Bootstrap

```bash
# Once: bring persistent stack up first (creates EBS volumes + ECR).
cd ../persistent && terraform apply

# Each session: bring ephemeral up.
cd ../ephemeral
cp backend.tf.example backend.tf
sed -i "s/028708951757/$(aws sts get-caller-identity --query Account --output text)/" backend.tf
terraform init
terraform apply
```

## Verify after apply (~12–15 min)

```bash
# 1. Get kubeconfig
$(terraform output -raw kubeconfig_command)

# 2. Nodes
kubectl get nodes -L node-type,nvidia.com/gpu
# Expect:
#   head   ... node-type=head
#   gpu    ... node-type=gpu-worker  nvidia.com/gpu=true

# 3. GPU advertised (the critical check — AMI + device plugin together)
eval "$(terraform output -raw gpu_check_command)"
# Expect 1 per GPU node. If 0/empty:
#   - check `aws eks describe-nodegroup ... | jq .nodegroup.amiType` → should be AL2023_X86_64_NVIDIA
#   - check `kubectl -n kube-system logs ds/nvidia-device-plugin-daemonset`

# 4. EBS CSI controller
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-ebs-csi-driver

# 5. PVCs bound (lazy — bind on first consumer because WaitForFirstConsumer)
kubectl -n llm-chat get pvc
# qdrant-data-pvc and llm-cache-pvc may show Pending until a pod claims them.
# The PVs themselves should be Available:
kubectl get pv qdrant-data-pv llm-cache-pv
```

## Common gotchas

| Symptom | Likely cause |
|---|---|
| GPU pod stuck `Pending` with "0/2 nodes available, 1 Insufficient nvidia.com/gpu" | Device plugin not running. Re-check AMI type. |
| PVC stuck `Pending` after pod schedules | EBS CSI IRSA not wired. Check `aws_iam_role.ebs_csi` and the addon's `service_account_role_arn`. |
| PV stays `Released` after a pod deletes | Old `claimRef` lingers. `kubectl patch pv qdrant-data-pv -p '{"spec":{"claimRef":null}}'` |
| Spot eviction kills GPU node mid-demo | Set `gpu_capacity_type = "ON_DEMAND"` before high-stakes demos. ~$1/h × 4h ≈ $4 overhead. |
| `terraform destroy` complains about claimRef on PV | PVCs must be deleted before PVs. `cluster-down` script does this. |

## Cost while up

Hourly: $0.10 (EKS) + $0.32 (g6.xlarge spot) + $0.06 (m6i.xlarge spot) + ~$0.05 misc = **~$0.55/h**.

80 hours/month ≈ **$46/month** total (with persistent stack ~$5/mo always-on for storage).

## Destroy

```bash
make cluster-down
# or manually:
terraform destroy
```

EBS volumes (qdrant-data + llm-cache) are **NOT** destroyed — they live in the persistent stack with `prevent_destroy = true`.
