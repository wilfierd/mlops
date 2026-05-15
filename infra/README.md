# Infra — AWS EKS + KubeRay for the LLM chat app

Terraform stack for a CPU-only Ray Serve LLM chat deployment on EKS.

## Layout

```
infra/
├── environments/                # LIVE config — one dir per env
│   └── dev/
│       ├── versions.tf          # provider/terraform version pins
│       ├── providers.tf         # aws + kubernetes + helm + kubectl wired to EKS
│       ├── backend.tf.example   # copy to backend.tf for S3 remote state
│       ├── variables.tf         # all knobs the env exposes
│       ├── main.tf              # composes modules
│       ├── outputs.tf
│       └── terraform.tfvars.example
├── modules/                     # REUSABLE — no env-specific defaults
│   ├── network/                 # VPC (2 AZ control plane + 1 AZ workers + 1 NAT)
│   ├── ecr/                     # ECR repo + lifecycle policy
│   ├── eks/                     # EKS cluster + MNG (wraps terraform-aws-modules)
│   └── kuberay/                 # KubeRay operator (Helm) + RayService (kubectl)
├── scripts/
│   └── push_image.sh            # build + ECR login + push + roll pods
└── README.md                    # this file
```

Each module has its own `versions.tf`, `README.md`, `variables.tf`,
`outputs.tf` and `main.tf` so it drops into another repo without changes.

## Add a new environment

```bash
cp -r environments/dev environments/staging
# edit environments/staging/terraform.tfvars + backend.tf
cd environments/staging
terraform init && terraform apply
```

## Prereqs

- AWS account + admin-ish creds (`aws sts get-caller-identity` works).
- Tools: `terraform >= 1.6`, `aws` v2, `kubectl >= 1.30`, `docker` or `podman`.
- Quota in the target region: 1 EKS cluster, 1 NAT gateway, 1 EIP, 2..4
  `t3.xlarge` instances.

## Deploy

```bash
cd environments/dev
cp terraform.tfvars.example terraform.tfvars   # edit region, sizes, model, ...
terraform init
terraform apply
```

One `terraform apply` is enough — `kubectl_manifest` defers API calls to
apply time, so no two-phase apply is needed.

Apply runs ~15-20 minutes (most of it is the EKS control plane).

## Access

```bash
cd environments/dev
$(terraform output -raw kubeconfig_command)   # writes ~/.kube/config entry

kubectl -n kuberay-system get pods            # operator should be Running
kubectl -n llm-chat get rayservice,pods,svc   # cluster pods come up
```

## Push the image

The cluster comes up with `ImagePullBackOff` until you push the app image to
ECR (the ECR repo is created empty by Terraform).

```bash
infra/scripts/push_image.sh                   # ENV=dev default
# or for another env:
ENV=staging infra/scripts/push_image.sh
```

The script:

1. Reads `region`, `ecr_repository_url`, `model_id`, `image_tag` from
   `terraform output` of `environments/${ENV}/`.
2. `docker login` to ECR.
3. `docker build` with `PRELOAD_MODEL=true` (bakes the HF model into the
   image, so pods don't depend on Hugging Face Hub egress at start time).
4. `docker push`.
5. `kubectl delete pod --all --force` to roll the RayService onto the new
   image.

After ~3-5 minutes pods become Ready.

## Use the chat UI

```bash
cd environments/dev
$(terraform output -raw port_forward_command)
# Open http://127.0.0.1:8000
```

## Iterate

```bash
# Edit app/server.py, then:
IMAGE_TAG=0.1.1 infra/scripts/push_image.sh
```

Manifest tag is controlled by `image_tag` variable — to force pods to a new
tag without re-applying TF just push the same tag and run the script.

## Cost (approx)

| Item | $/month (on-demand) |
| --- | --- |
| EKS control plane | $73 |
| 2 × t3.xlarge | ~$240 |
| NAT GW + traffic | $33 + data |
| ECR | ~$1 |
| **Total** | **~$350-400** |

To pause without destroying:

```bash
cd environments/dev
terraform apply -var node_desired_size=0   # scales the MNG to zero
```

To tear everything down:

```bash
terraform destroy
```

## Tuning highlights

| Variable | Effect |
| --- | --- |
| `node_instance_types` | Default `t3.xlarge` (cheap, burstable). For load tests use `m6i.2xlarge` or `c6i.2xlarge`. |
| `node_capacity_type` | `ON_DEMAND` default; `SPOT` cuts ~70%. |
| `node_min_size` / `_desired` / `_max` | MNG autoscale bounds. |
| `ray_replica_max` | Ray Serve max replicas. |
| `ray_replica_cpus` | CPU each Ray Serve replica reserves. |
| `model_id` | HF model. Pair with bigger nodes for >1B parameter models. |

## Notes

- `t3.xlarge` is **burstable**. Sustained load test will burn CPU credits and
  throttle. Switch to `m6i.2xlarge`/`c6i.2xlarge` for real benchmarks.
- Workers are in a single AZ to keep cost low. For production set
  `node_subnet_ids` (in `modules/eks/main.tf`) to all private subnets and
  remove `single_nat_gateway` in `modules/network/main.tf`.
- Remote state: copy `environments/dev/backend.tf.example` to `backend.tf`
  and adjust before `terraform init` if you want shared state.
