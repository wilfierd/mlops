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

## What this stack creates (rev5 cost-first default)

| Resource | Notes |
|---|---|
| EKS control plane **v1.34** | $0.10/h. Standard support — avoid extended-support fee on 1.30. |
| Head MNG **(m6i.large SPOT)** | 1 untainted x86 node, hosts EKS add-ons + Ray head + FastAPI + Embedder + Qdrant. 2 vCPU / 8 GiB; ~$0.030/h. Tight packing — see doc rev5 §4.2. |
| GPU MNG **(g4dn.xlarge ON_DEMAND)** | 0–2 nodes, T4 16GB, AL2023_x86_64_NVIDIA AMI. ~$0.526/h while up. Default is on-demand because new accounts often have `All G and VT Spot Instance Requests = 0`. **No FP8 KV** — vllm args use `--kv-cache-dtype=auto`. |
| addons: vpc-cni, coredns, kube-proxy, **aws-ebs-csi-driver** (with IRSA) | |
| Helm: `nvidia-device-plugin` v0.14.5 | tolerates `nvidia.com/gpu` taint |
| K8s namespace `llm-chat` | |
| StorageClass `gp3-retain` | `WaitForFirstConsumer` + `Retain` |
| PV `qdrant-data-pv` → bound to EBS `vol-...` (persistent stack) | survives destroy |
| PV `llm-cache-pv` → bound to EBS `vol-...` (persistent stack) | survives destroy |
| PVC `qdrant-data-pvc`, `llm-cache-pvc` in `llm-chat` namespace | |

### Upgrade to stable profile

For FP8 KV + 14B AWQ support + lower latency, override in tfvars:

```hcl
head_instance_types = ["m6i.xlarge"]               # more headroom; $0.060/h
gpu_instance_types  = ["g6.xlarge", "g5.xlarge"]   # L4 24GB / A10G 24GB; ~$0.32–0.40/h
```

And switch vllm-openai args (see comments in `k8s/vllm-server.yaml`).

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
| CoreDNS / EBS CSI stuck `DEGRADED` with `untolerated taint(s)` | The only non-GPU node was tainted. Head node must stay untainted unless you add a separate system/ops node. |
| GPU pod stuck `Pending` with "0/2 nodes available, 1 Insufficient nvidia.com/gpu" | Device plugin not running. Re-check AMI type = `AL2023_x86_64_NVIDIA`. |
| Head pod Pending after `kubectl apply` (Qdrant/vllm-server-0 OK but app actor not scheduling) | `m6i.large` allocatable ~1.8 vCPU is tight. Override `head_instance_types = ["m6i.xlarge"]` in tfvars. |
| PVC stuck `Pending` after pod schedules | EBS CSI IRSA not wired. Check `aws_iam_role.ebs_csi` and the addon's `service_account_role_arn`. |
| PV stays `Released` after a pod deletes | Old `claimRef` lingers. `kubectl patch pv qdrant-data-pv -p '{"spec":{"claimRef":null}}'` |
| vllm-server-0 CrashLoopBackOff with `CUDA out of memory` | T4 + AWQ + KV cache too tight at `--gpu-memory-utilization=0.82`. Drop `--max-num-seqs` to 2, or `--max-model-len` to 3072. |
| GPU node group fails with `MaxSpotInstanceCountExceeded` | Spot quota for `All G and VT Spot Instance Requests` is 0. Default uses `ON_DEMAND`; only set `gpu_capacity_type = "SPOT"` after quota is approved. |
| `terraform destroy` complains about claimRef on PV | PVCs must be deleted before PVs. `cluster-down` script does this. |

## Cost while up

Default dev profile (g4dn on-demand + m6i.large spot):

| Component | Rate | 80h/month |
|---|---:|---:|
| EKS control plane | $0.10/h | $8.00 |
| g4dn.xlarge ON_DEMAND (T4) | $0.526/h | $42.08 |
| m6i.large SPOT | $0.030/h | $2.40 |
| EBS root + misc | — | ~$2 |
| Persistent storage (always-on) | — | ~$3–5 |
| **Total default** | | **~$60 / month at 80h** |

After G/VT Spot quota is approved, set `gpu_capacity_type = "SPOT"` to reduce the GPU line to roughly `$16.80 / 80h` and total to roughly `$35 / month`.

## Destroy

```bash
make cluster-down
# or manually:
terraform destroy
```

EBS volumes (qdrant-data + llm-cache) are **NOT** destroyed — they live in the persistent stack with `prevent_destroy = true`.
