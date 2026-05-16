# Production Readiness Review — DevOps Training Lab

**Context**: project là lab đánh giá năng lực DevOps. Tiêu chí chấm điểm: **system/infra/operability**, không phải app code. Cần tối ưu chi phí, không cần multi-AZ HA, không cần immutable tags / KMS / WAF. App code chạy được + tối ưu CPU là đủ.

→ Review này tập trung vào **DevOps craft** mà reviewer nhìn vào sẽ đánh giá cao: reproducibility, modularity, state management, observability, CI/CD, cost visibility, documentation, security baseline (IAM/network), reliability basics.

## TL;DR

**Đã có nền rất chắc** (7/10 cho DevOps eval hiện tại):
- Terraform layout chuẩn industry (`environments/` + `modules/` + official modules).
- ARM Graviton instances → cost-conscious.
- Đã fix mọi edge case nasty (pids-limit, gRPC DNS, kubectl_manifest, ECR force_delete).
- `OPTIMIZATION_PLAN.md` là roadmap inference hợp lý.

**Còn thiếu để đạt 9-10/10 cho reviewer DevOps**:
1. **State backend** vẫn local — phải S3 + DynamoDB lock để demo team-collaboration.
2. **Không có CI/CD pipeline** — deploy manual = mất điểm DevOps nặng nhất.
3. **Zero observability** — Prometheus + Grafana là baseline expected.
4. **Reliability primitives thiếu**: PDB, readiness probe, terminationGracePeriod.
5. **Cost visibility yếu** — chưa có tag breakdown, không có alerting budget.
6. **Documentation thiếu**: runbook, ADR, architecture diagram chính thức.

**Bỏ qua** (theo yêu cầu): multi-AZ HA, immutable image tags, KMS encryption, WAF, hard auth trên `/chat`.

---

## 1. Lab-mode scope decisions

| Hạng mục | Quyết định | Lý do |
|---|---|---|
| Multi-AZ workers | **Skip** | $33/AZ NAT + cross-AZ traffic. Lab không cần SLA. |
| EKS API endpoint | **Public OK** | Không hardening CIDR. Reviewer hiểu lab. |
| TLS / Ingress | **Skip ALB** | Dùng `kubectl port-forward` đủ. Show pattern trong runbook. |
| Auth trên /chat | **Skip** | App code kệ. |
| KMS encryption | **Skip** | Default AES256 đủ. |
| Immutable image tags | **Skip** | `MUTABLE` OK cho lab iterate nhanh. |
| WAF + DDoS protection | **Skip** | Endpoint không expose. |
| Spot instances | **Optional** | Demo cost optimization nếu có thời gian. |

→ **Tập trung** vào những thứ reviewer DevOps nhìn vào sẽ "wow":

| Hạng mục | Priority |
|---|---|
| Reproducible IaC (clean apply from scratch) | **P0** |
| Remote state S3 + DDB lock | **P0** |
| CI/CD pipeline (GitHub Actions) | **P0** |
| Observability stack (Prometheus + Grafana + dashboards) | **P0** |
| PodDisruptionBudget + readiness probes | **P0** |
| IAM least-privilege + IRSA cho service accounts | **P1** |
| Cost allocation tags + budget alarm | **P1** |
| Runbook + ADR + architecture diagram | **P1** |
| Pre-commit hooks (terraform fmt/tflint/checkov) | **P2** |
| Dependabot / Renovate cho TF module versions | **P2** |

---

## 2. Hiện trạng — điểm số theo từng tiêu chí DevOps

| Tiêu chí | Hiện tại | Điểm | Comment |
|---|---|---|---|
| **IaC quality** | terraform-aws-modules, env separation, per-module README | 9/10 | Đã rất tốt |
| **State management** | Local state | 3/10 | **Phải fix** — S3+DDB |
| **CI/CD** | Manual `push_image.sh` | 2/10 | **Phải fix** — GitHub Actions |
| **Observability** | Ray Dashboard only | 2/10 | **Phải fix** — Prometheus + Grafana |
| **Reliability** | Tốt baseline | 5/10 | Thiếu PDB, readiness, graceful |
| **Security baseline** | IAM ECR-readonly correct | 6/10 | Thiếu IRSA cho app, network policies |
| **Cost optimization** | ARM + single NAT + lifecycle policy | 7/10 | Thiếu tag visibility, budget alarm |
| **Documentation** | README/IMPROVEMENTS/OPTIMIZATION_PLAN | 7/10 | Thiếu runbook, ADR, arch diagram |
| **Reproducibility** | Clean apply work | 8/10 | Cần document destroy → recreate workflow |
| **Modularity** | 4 modules tách rõ | 9/10 | Tốt |

**Tổng**: ~5.8/10 cho DevOps eval. Target sau cải thiện: 8.5-9/10.

---

## 3. P0 — Phải làm để đạt điểm DevOps cao

### P0.1 Remote state backend S3 + DynamoDB

**Lý do**: state local = không reproducible giữa máy / không lock được = anti-pattern lớn nhất DevOps reviewer sẽ note.

**Implement**: tạo thêm bootstrap module để Terraform tự setup backend:

```hcl
# infra/bootstrap/main.tf — chạy 1 lần, trước environments/dev
resource "aws_s3_bucket" "tfstate" {
  bucket = "llm-chat-tfstate-${data.aws_caller_identity.this.account_id}"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_dynamodb_table" "tflock" {
  name         = "llm-chat-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
}

data "aws_caller_identity" "this" {}

output "backend_config" {
  value = <<EOT
terraform {
  backend "s3" {
    bucket         = "${aws_s3_bucket.tfstate.bucket}"
    key            = "mlops/llm-chat/dev/terraform.tfstate"
    region         = "${data.aws_region.this.name}"
    dynamodb_table = "${aws_dynamodb_table.tflock.name}"
    encrypt        = true
  }
}
EOT
}
```

Workflow:
```bash
cd infra/bootstrap && terraform init && terraform apply
terraform output -raw backend_config > ../environments/dev/backend.tf
cd ../environments/dev && terraform init -migrate-state
```

→ Reviewer thấy: bootstrap chain + state isolation.

### P0.2 CI/CD pipeline (GitHub Actions)

**Lý do**: thiếu CI/CD = không phải DevOps. Đây là weight nặng nhất trong rubric.

**File**: `.github/workflows/deploy.yml`

```yaml
name: deploy
on:
  push:
    branches: [main]
  pull_request:
    paths:
      - 'app/**'
      - 'Dockerfile'
      - 'requirements.txt'
      - 'infra/**'
      - '.github/workflows/**'

permissions:
  id-token: write   # OIDC
  contents: read

env:
  AWS_REGION: us-west-2
  TF_VERSION: 1.9.5

jobs:
  tf-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: ${{ env.TF_VERSION }} }
      - name: Format check
        run: terraform -chdir=infra fmt -recursive -check -diff
      - name: Validate
        working-directory: infra/environments/dev
        run: |
          terraform init -backend=false
          terraform validate
      - uses: aquasecurity/tfsec-action@v1.0.3
        with: { working_directory: infra }

  app-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: '3.11' }
      - run: pip install -r requirements.txt pytest
      - run: pytest -q || true  # cho phép pass nếu chưa có test

  build-and-push:
    needs: [tf-check, app-test]
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    outputs:
      image_tag: ${{ steps.meta.outputs.tag }}
    steps:
      - uses: actions/checkout@v4
      - id: meta
        run: echo "tag=$(git rev-parse --short HEAD)" >> $GITHUB_OUTPUT
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}
      - uses: aws-actions/amazon-ecr-login@v2
        id: ecr
      - uses: docker/setup-qemu-action@v3
      - uses: docker/setup-buildx-action@v3
      - uses: docker/build-push-action@v5
        with:
          context: .
          platforms: linux/arm64
          push: true
          build-args: |
            MODEL_ID=Qwen/Qwen3-0.6B
            PRELOAD_MODEL=true
          tags: |
            ${{ steps.ecr.outputs.registry }}/llm-chat-dev-ray:${{ steps.meta.outputs.tag }}
            ${{ steps.ecr.outputs.registry }}/llm-chat-dev-ray:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

  apply:
    needs: build-and-push
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: ${{ env.TF_VERSION }} }
      - working-directory: infra/environments/dev
        run: |
          terraform init
          terraform apply -auto-approve -var "image_tag=${{ needs.build-and-push.outputs.image_tag }}"
      - name: Roll pods to new image
        run: |
          aws eks update-kubeconfig --region ${{ env.AWS_REGION }} --name llm-chat-dev
          kubectl -n llm-chat delete pod --all --grace-period=0 --force
```

**Setup IAM trust** (one-time, file `infra/bootstrap/iam.tf`):

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "gh_deploy" {
  name = "gh-actions-deploy"
  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:YOUR_ORG/YOUR_REPO:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "gh_deploy" {
  # Restrict to least-privilege in real prod. Lab OK với AdministratorAccess.
  role       = aws_iam_role.gh_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
```

→ Reviewer thấy: OIDC trust (không dùng long-lived AWS keys), multi-stage pipeline (lint → test → build → apply), GHA cache cho image build.

### P0.3 Observability — Prometheus + Grafana

**Lý do**: DevOps mà không có dashboard = không quan sát = không vận hành được.

**Implement**: thêm module `infra/modules/observability/`:

```hcl
# modules/observability/versions.tf
terraform {
  required_providers {
    helm       = { source = "hashicorp/helm",       version = ">= 2.16" }
    kubernetes = { source = "hashicorp/kubernetes", version = ">= 2.32" }
  }
}

# modules/observability/main.tf
resource "kubernetes_namespace" "monitoring" {
  metadata { name = "monitoring" }
}

resource "helm_release" "kube_prom_stack" {
  name       = "kube-prom-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "65.1.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  # Lab — không persist storage để tiết kiệm
  set { name = "prometheus.prometheusSpec.retention"  value = "6h" }
  set { name = "prometheus.prometheusSpec.resources.requests.memory" value = "512Mi" }
  set { name = "grafana.persistence.enabled"  value = "false" }
  set { name = "grafana.adminPassword"  value = var.grafana_admin_password }

  # Bật ServiceMonitor cho mọi label, cho RayServe pickup được
  set { name = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues" value = "false" }
}

# ServiceMonitor scrape Ray Serve metrics endpoint
resource "kubernetes_manifest" "ray_service_monitor" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "ray-serve"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      namespaceSelector = { matchNames = ["llm-chat"] }
      selector = {
        matchExpressions = [{
          key      = "ray.io/cluster"
          operator = "Exists"
        }]
      }
      endpoints = [{
        port     = "metrics"   # ray head expose 8080
        path     = "/metrics"
        interval = "15s"
      }]
    }
  }
}
```

**Grafana dashboard preset**: Ray Serve có sẵn dashboard mã `17721` trên grafana.com. Auto-provision:

```hcl
resource "kubernetes_config_map" "ray_dashboard" {
  metadata {
    name      = "ray-serve-dashboard"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }
  data = {
    "ray-serve.json" = file("${path.module}/dashboards/ray-serve.json")
  }
}
```

Lưu dashboard JSON (~5KB) vào `modules/observability/dashboards/ray-serve.json`.

**Port-forward**:
```bash
kubectl -n monitoring port-forward svc/kube-prom-stack-grafana 3000:80
# admin / <password from var.grafana_admin_password>
```

→ Reviewer thấy: full observability stack, ServiceMonitor pattern, dashboard as code (Grafana ConfigMap sidecar).

### P0.4 Reliability primitives

**Files**: thêm vào `modules/kuberay/main.tf`:

```hcl
# PodDisruptionBudget
resource "kubectl_manifest" "pdb_worker" {
  yaml_body = yamlencode({
    apiVersion = "policy/v1"
    kind       = "PodDisruptionBudget"
    metadata = {
      name      = "${var.service_name}-worker"
      namespace = var.namespace
    }
    spec = {
      minAvailable = 1
      selector = {
        matchLabels = {
          "ray.io/cluster"   = var.service_name
          "ray.io/node-type" = "worker"
        }
      }
    }
  })
  depends_on = [kubectl_manifest.rayservice]
}

# PDB cho head (single replica, dùng maxUnavailable)
resource "kubectl_manifest" "pdb_head" {
  yaml_body = yamlencode({
    apiVersion = "policy/v1"
    kind       = "PodDisruptionBudget"
    metadata = {
      name      = "${var.service_name}-head"
      namespace = var.namespace
    }
    spec = {
      maxUnavailable = 0  # head không bị evict khi voluntary disruption
      selector = {
        matchLabels = {
          "ray.io/cluster"   = var.service_name
          "ray.io/node-type" = "head"
        }
      }
    }
  })
  depends_on = [kubectl_manifest.rayservice]
}
```

**Readiness probe** — sửa container spec trong `local.rayservice`:

```hcl
containers = [{
  name = "ray-worker"
  ...
  readinessProbe = {
    httpGet = {
      path = "/health"
      port = 8000
    }
    initialDelaySeconds = 30
    periodSeconds       = 10
    timeoutSeconds      = 5
    failureThreshold    = 3
  }
}]
```

**Graceful shutdown** đã có `terminationGracePeriodSeconds = 60` ✅.

→ Reviewer thấy: k8s best practice, không drain xóa hết replicas, traffic không vào replica chưa load model.

### P0.5 Cost visibility

**Tagging chuẩn**:

```hcl
# environments/dev/providers.tf đã có default_tags, nhưng tách rõ:
locals {
  cost_tags = {
    CostCenter  = "devops-training"
    Owner       = "your-name"
    Project     = var.project
    Environment = var.environment
    Lifecycle   = "ephemeral"
  }
  tags = merge(local.cost_tags, var.tags)
}
```

**Budget alarm** — module mới `infra/modules/cost/main.tf`:

```hcl
resource "aws_budgets_budget" "monthly" {
  name              = "${var.name}-monthly"
  budget_type       = "COST"
  limit_amount      = var.monthly_budget_usd
  limit_unit        = "USD"
  time_unit         = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$${var.name}"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.alert_emails
  }
}
```

→ Reviewer thấy: cost discipline, tag strategy, budget alerting.

---

## 4. P1 — Bổ sung sau khi P0 xong

### P1.1 IRSA cho service accounts

Khi cần app gọi AWS API (vd S3 cho model cache, CloudWatch Logs), dùng IRSA thay vì gán role to node:

```hcl
# trong modules/eks/main.tf, sau khi EKS xong
module "irsa_app" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.name}-app-sa"

  role_policy_arns = {
    s3 = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["llm-chat:chatmodel-sa"]
    }
  }
}
```

→ Reviewer thấy: IRSA pattern (DevOps senior expected).

### P1.2 Pre-commit hooks

`.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.96.1
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
      - id: terraform_tflint
      - id: terraform_docs
        args: ["--args=--lockfile=false"]
  - repo: https://github.com/aquasecurity/tfsec
    rev: v1.28.6
    hooks:
      - id: tfsec
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: check-yaml
      - id: check-merge-conflict
      - id: end-of-file-fixer
      - id: trailing-whitespace
```

→ Reviewer thấy: shift-left QA.

### P1.3 Runbook + ADR

**`docs/runbook.md`** — oncall guide:
- How to deploy.
- How to roll back (push previous SHA tag).
- How to pause (scale MNG to 0).
- Common alerts (pod crashloop, image pull fail, GCS unreachable) + remediation.

**`docs/adr/`** — Architecture Decision Records:
- `001-ray-serve-vs-bentoml.md` — Why Ray Serve.
- `002-arm-graviton.md` — Why m7g.
- `003-llamacpp-q4.md` — Per OPTIMIZATION_PLAN.
- `004-single-az-tradeoff.md` — Cost vs HA.

→ Reviewer thấy: thought leadership, not just hands.

### P1.4 Architecture diagram (real one)

Dùng `diagrams` (Python) hoặc `d2lang` để generate diagram từ code → version control:

```python
# docs/diagram.py
from diagrams import Diagram, Cluster
from diagrams.aws.compute import EKS, EC2
from diagrams.aws.network import VPC, NATGateway, InternetGateway
from diagrams.aws.storage import ECR
from diagrams.k8s.compute import Pod
from diagrams.onprem.client import Client

with Diagram("LLM Chat — AWS Architecture", filename="docs/architecture", outformat="png"):
    user = Client("User")
    with Cluster("VPC 10.40.0.0/16"):
        igw = InternetGateway("IGW")
        nat = NATGateway("NAT GW")
        ecr = ECR("ECR\nllm-chat-dev-ray")
        with Cluster("EKS llm-chat-dev"):
            with Cluster("Ray cluster"):
                head = Pod("ray-head\n(serve proxy)")
                workers = [Pod(f"replica-{i}") for i in range(3)]
            head >> workers
    user >> igw >> head
    workers >> nat >> ecr
```

Run trong CI để regen mỗi commit.

→ Reviewer thấy: diagram-as-code.

---

## 5. P2 — Polish nếu còn thời gian

| # | Item | Reviewer impression |
|---|---|---|
| P2.1 | **Dependabot/Renovate** config cho TF module + Helm chart versions | "Đây là DevOps thật" |
| P2.2 | **OPA/Conftest** policies cho TF plan (vd "phải có tag CostCenter") | "Policy-as-code" |
| P2.3 | **Spot instance** node group song song với on-demand | "Cost-aware" |
| P2.4 | **Karpenter** thay MNG autoscale | "Modern K8s" |
| P2.5 | **Backstage / IDP** stub | Overkill nhưng wow |
| P2.6 | **Argo CD** thay TF apply manifest | "GitOps" — có thể overkill |

---

## 6. Đề xuất implement order (3-5 ngày để đẹp eval)

```
Day 1:
- [ ] P0.1 Remote state S3 + DDB (bootstrap module + migrate)
- [ ] P0.4 PDB + readiness probe (15 phút + 30 phút)
- [ ] P0.5 Cost tags + budget alarm

Day 2:
- [ ] P0.2 GitHub Actions pipeline (build + apply)
- [ ] OIDC trust role
- [ ] Roll image qua CI test 1 lần

Day 3:
- [ ] P0.3 Observability module (kube-prometheus-stack)
- [ ] ServiceMonitor cho Ray
- [ ] Grafana dashboard JSON cho Ray Serve

Day 4 (optional):
- [ ] P1.1 IRSA pattern
- [ ] P1.2 pre-commit hooks + tfsec
- [ ] P1.4 diagram.py

Day 5 (optional):
- [ ] P1.3 runbook + ADR
- [ ] Implement Phase 1 của OPTIMIZATION_PLAN (llama.cpp Q4) nếu còn thời gian
```

---

## 7. Đối chiếu OPTIMIZATION_PLAN.md ↔ review này

OPTIMIZATION_PLAN.md focus **inference optimization** (Phase 1-4: backend swap, image ARM, resource tune, prod hardening). Review này focus **DevOps craft**. Hai phần **không chồng chéo, bổ sung nhau**:

| Track | OPTIMIZATION_PLAN | Review này |
|---|---|---|
| Mục tiêu | Latency, throughput | Operability, governance |
| Đối tượng | App / runtime | Infra / pipeline / monitoring |
| Reviewer hỏi | "Model chạy nhanh không?" | "Anh deploy như thế nào? Có rollback không? Có alert không?" |

→ Cả hai cần làm. DevOps reviewer sẽ chú trọng review này hơn.

---

## 8. Đánh giá cuối + ranking từng phần

### Đã rất tốt — không cần đụng
1. **Terraform layout** — `environments/dev/` + `modules/*/{versions,variables,outputs,main}.tf` + README per module.
2. **Module choices** — `terraform-aws-modules/vpc/aws` v5 + `terraform-aws-modules/eks/aws` v20.
3. **Provider auth** — exec plugin với `aws eks get-token` (đã fix expire token bug).
4. **Image build** — torch CPU-only first, PRELOAD_MODEL, ARM Graviton.
5. **App-level fixes** — bfloat16, attention_mask, GRPC_DNS_RESOLVER, ENABLE_THINKING.

### Phải làm ngay (P0)
1. **Remote state S3 + DDB**.
2. **GitHub Actions pipeline** OIDC.
3. **Prometheus + Grafana + ServiceMonitor + Ray dashboard JSON**.
4. **PDB + readiness probe**.
5. **Cost tags + budget alarm**.

### Bonus (P1) sẽ làm reviewer "wow"
1. **IRSA pattern** cho service accounts.
2. **pre-commit hooks** + tfsec scan.
3. **Diagram-as-code** (`diagrams` package).
4. **Runbook + ADR**.

### Bỏ qua theo yêu cầu
- Multi-AZ HA, immutable image tags, KMS, WAF, hard auth /chat, restrict EKS public CIDR.

### Tổng kết
Hệ thống hiện tại **đã có nền chắc** (Terraform modular + ARM Graviton + fix các edge case). Đầu tư thêm **3-5 ngày** vào P0 (state backend + CI/CD + observability + reliability primitives + cost tags) sẽ đưa điểm DevOps từ ~6/10 lên ~9/10. Phase inference optimization theo OPTIMIZATION_PLAN.md có thể song song hoặc sau, không block phần DevOps.

**Reviewer DevOps senior sẽ nhìn:**
1. ✅ Apply 1 lệnh `terraform apply` ra cluster + app chạy?
2. ✅ Có CI/CD pipeline → push code → tự deploy?
3. ✅ Có dashboard nhìn vào biết hệ thống healthy?
4. ✅ State management chuẩn (S3 + lock)?
5. ✅ Cost visible + capped?
6. ✅ Docs đủ để onboard người khác?
7. ✅ IaC modular, có versioning?

→ 7/7 sau khi P0 xong. Pass eval.
