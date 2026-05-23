# `dev/persistent/` — long-lived infrastructure

## Convention (hard rule)

| Stack | Lifecycle |
|---|---|
| `persistent/` (this dir) | **Created once. DO NOT destroy** in daily workflow. |
| `ephemeral/` (sibling)   | Destroy/apply freely each session. |

Running `terraform destroy` here would wipe ECR images, S3 data, Qdrant vectors, and the LLM model cache. To prevent that, **four resources are guarded with `lifecycle { prevent_destroy = true }`**:

- `aws_ecr_repository.this` (in `modules/ecr/main.tf`)
- `aws_s3_bucket.data`
- `aws_ebs_volume.qdrant_data`
- `aws_ebs_volume.llm_cache`
- `aws_iam_openid_connect_provider.github` (if configured)

If you genuinely need to destroy one (migrating accounts, etc.), remove the lifecycle block from the resource, `apply`, then `destroy`.

## Resources owned

| Resource | Purpose | Why persistent |
|---|---|---|
| VPC + IGW + public subnets | Network | Recreating VPC means new CIDR, new ENI plumbing — too expensive |
| ECR repo (`llm-chat-app`) | App proxy image | Avoid 30-min image rebuild on every cluster-up |
| S3 bucket (`llm-chat-data-<acct>`) | Raw docs + Qdrant snapshots | User data — cannot be lost |
| EBS `qdrant-data` 10 GiB | Vector DB storage | Ingested documents survive cluster destroy |
| EBS `llm-cache` 20 GiB | HF model cache | Avoid re-downloading 5GB AWQ model |
| (optional) IAM OIDC + role | GitHub Actions | CI workflows |

## Network posture — lab mode trade-off

`terraform.tfvars` defaults:

```hcl
enable_nat_gateway       = false   # no $33/mo NAT
# (workers_in_public_subnet is derived = !enable_nat_gateway)
# map_public_ip_on_launch is set inside the network module accordingly.
```

What this means:

- Worker nodes (head + GPU) run in **public subnets** with a public IP.
- Outbound traffic (HF model pull, ECR pull, package install) goes via **IGW** — no NAT.
- Inbound is **still blocked** by node security groups + EKS API SG.
- App access is via `kubectl port-forward` to `ClusterIP` services. **No `LoadBalancer` type services** in this setup (would expose to internet).

Acceptable for personal lab. For production:

- Flip `enable_nat_gateway = true` → workers in private subnet + NAT ($33/mo).
- Or add VPC endpoints for S3 + ECR + STS + CloudWatch (~$15/mo, more secure than NAT).

## Access pattern (no LB exposed)

```bash
# kubectl context already pointing at the ephemeral EKS cluster
kubectl -n llm-chat port-forward svc/llm-chat-serve-svc 8000:8000
curl localhost:8000/healthz

# vllm-openai direct (debug)
kubectl -n llm-chat port-forward svc/vllm-server 8000:8000
curl localhost:8000/v1/models
```

## Cost when idle (no ephemeral cluster up)

~$3–5 / month (EBS + S3 + ECR storage only).

## Cost when idle (no ephemeral cluster up)

~$3–5 / month (EBS + S3 + ECR storage only).

## Bootstrap

```bash
# Once per account:
cd infra/bootstrap
terraform init && terraform apply         # creates TF state bucket + lock table

# This stack:
cd ../environments/dev/persistent
cp backend.tf.example backend.tf
sed -i "s/028708951757/$(aws sts get-caller-identity --query Account --output text)/" backend.tf
terraform init
terraform plan
terraform apply
```

## After apply

The ephemeral stack (`../ephemeral/`) reads outputs via `terraform_remote_state` — no need to copy values around. To inspect:

```bash
terraform output qdrant_volume_id
terraform output ecr_app_url
terraform output data_bucket
```

## Modifying

Safe to change at any time:
- `tags`, `github_repo`, `ecr_force_delete`

Changes that need care (will recreate the resource):
- `worker_az` — EBS volumes pinned to AZ. Changing requires snapshot/restore.
- `vpc_cidr` — destroys VPC + all dependent resources. Don't.

## Tearing down (rare)

```bash
# Remove prevent_destroy from each resource lifecycle block, then:
terraform destroy
```

You should only do this if migrating to a different account/region.

## Bind from `ephemeral/`

The PVs in `ephemeral/` reference these EBS volume IDs:

```hcl
data "terraform_remote_state" "persistent" {
  backend = "s3"
  config = {
    bucket = "llm-chat-tfstate-<account>"
    key    = "mlops/llm-chat/dev/persistent.tfstate"
    region = "us-west-2"
  }
}

# In a PV manifest:
csi {
  driver       = "ebs.csi.aws.com"
  volumeHandle = data.terraform_remote_state.persistent.outputs.qdrant_volume_id
  fsType       = "ext4"
}
```
