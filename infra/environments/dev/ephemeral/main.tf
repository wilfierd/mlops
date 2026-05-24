###############################################################################
# EPHEMERAL stack — EKS cluster + node groups + cluster-level Helm charts.
#
# CONVENTION:
#   - Persistent stack (sibling dir) holds VPC, ECR, S3, EBS, IAM/OIDC.
#   - This stack creates the EKS control plane + 2 MNGs (head x86, gpu).
#   - Safe to `terraform destroy` daily: EBS data (qdrant + llm-cache) is
#     retained on persistent volumes; PV manifests here re-bind to them on
#     next apply.
#
# Cost when up: lab scale-out profile uses 2 x g4dn.xlarge ON_DEMAND + 1 small
# head node + EKS control plane. This is intentionally above the single-GPU
# cost-first profile so the demo can show real GPU horizontal scaling.
###############################################################################

###############################################################################
# 1. EKS cluster + 2 node groups (head x86, gpu with NVIDIA AMI).
###############################################################################
module "eks" {
  source = "../../../modules/eks"

  name                     = local.name_prefix
  kubernetes_version       = var.eks_version
  vpc_id                   = local.vpc_id
  control_plane_subnet_ids = local.cp_subnet_ids
  node_subnet_ids          = local.node_subnet_ids

  node_groups = {
    # ---- Head: x86, hosts Ray head + FastAPI/QA + Embedder + Qdrant ----
    head = {
      instance_types = var.head_instance_types
      capacity_type  = var.head_capacity_type
      min_size       = var.head_min_size
      desired_size   = var.head_desired_size
      max_size       = var.head_max_size
      labels = {
        "node-type"        = "head"
        "ray.io/node-type" = "head"
      }
      # Do not taint the only non-GPU node. EKS-managed add-ons such as CoreDNS
      # and aws-ebs-csi-driver need an untainted node during cluster bootstrap.
      taints = []
      # ami_type auto-detected by module — m6i.xlarge → AL2023_x86_64_STANDARD.
    }

    # ---- GPU: NVIDIA AMI, hosts vllm-openai only ----
    gpu = {
      instance_types = var.gpu_instance_types
      capacity_type  = var.gpu_capacity_type
      min_size       = var.gpu_min_size
      desired_size   = var.gpu_desired_size
      max_size       = var.gpu_max_size
      ami_type       = var.gpu_ami_type # AL2023_x86_64_NVIDIA — driver preinstalled
      labels = {
        "node-type"      = "gpu-worker"
        "nvidia.com/gpu" = "true"
      }
      # vllm/vllm-openai includes CUDA/NVIDIA tooling and needs far more
      # imagefs space than the EKS default 20Gi root disk while pulling and
      # extracting layers. Model weights are still cached on llm-cache PVC.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
      taints = [{
        key    = "nvidia.com/gpu"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  extra_ecr_repository_arns = [local.ecr_app_arn]
  enable_ebs_csi_driver     = true

  tags = local.tags
}

###############################################################################
# 2. NVIDIA k8s device plugin — advertises nvidia.com/gpu on GPU nodes.
#
# The AL2023 NVIDIA AMI already includes the driver + nvidia-container-runtime.
# This Helm chart only deploys the device-plugin DaemonSet that talks to kubelet
# and exposes the GPU as a schedulable resource.
###############################################################################
resource "helm_release" "nvidia_device_plugin" {
  name             = "nvidia-device-plugin"
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = var.nvidia_device_plugin_version
  namespace        = "kube-system"
  create_namespace = false

  # Tolerate the gpu node taint so the daemonset can land there.
  set {
    name  = "tolerations[0].key"
    value = "nvidia.com/gpu"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  # Only schedule on GPU nodes (saves resources on head nodes).
  set {
    name  = "nodeSelector.node-type"
    value = "gpu-worker"
  }

  depends_on = [module.eks]
}

###############################################################################
# 3. Observability: kube-prometheus-stack + Ray/Qdrant/vLLM scraping +
#    Grafana dashboards (RAG pipeline + Ray cluster + LLM app).
###############################################################################
module "observability" {
  source = "../../../modules/observability"

  ray_namespace = var.kubernetes_namespace

  depends_on = [module.eks]
}

###############################################################################
# 4. S3 data access for the head node — allows Ray pods to read/write the
#    ingest bucket (docs/ + meta/ prefixes) without outbound IAM credentials.
#
#    Lab-grade: attaches an inline policy to the head MNG node role.
#    Production upgrade path: replace with IRSA (annotate the Ray head
#    ServiceAccount with a dedicated IAM role that scopes only to s3 data
#    bucket; remove this resource).
###############################################################################
resource "aws_iam_role_policy" "head_s3_data" {
  name = "${local.name_prefix}-head-s3-data"
  role = module.eks.node_iam_role_names["head"]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "IngestDataBucket"
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
      ]
      Resource = [
        "arn:aws:s3:::${local.data_bucket}",
        "arn:aws:s3:::${local.data_bucket}/*",
      ]
    }]
  })

  depends_on = [module.eks]
}
