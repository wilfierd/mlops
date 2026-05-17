module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.name
  cluster_version = var.kubernetes_version

  vpc_id                   = var.vpc_id
  subnet_ids               = var.control_plane_subnet_ids # control-plane ENIs
  control_plane_subnet_ids = var.control_plane_subnet_ids

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API_AND_CONFIG_MAP"

  cluster_addons = {
    coredns = {
      most_recent = true
      configuration_values = jsonencode({
        replicaCount = 2
      })
    }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true }
  }

  eks_managed_node_groups = {
    for k, v in var.node_groups : k => {
      name           = "${var.name}-${k}"
      subnet_ids     = var.node_subnet_ids
      instance_types = v.instance_types
      capacity_type  = v.capacity_type
      min_size       = v.min_size
      desired_size   = v.desired_size
      max_size       = v.max_size

      # EKS managed AMI must match instance arch. AL2023_x86_64 default in
      # the upstream module breaks ARM instances (t4g/m7g/c7g/...). We auto-
      # detect from the family prefix of the first instance type unless the
      # caller pins ami_type explicitly.
      ami_type = v.ami_type != "" ? v.ami_type : (
        can(regex("^(t4g|t6g|m6g|m7g|m8g|c6g|c7g|c8g|r6g|r7g|r8g|a1)\\.", v.instance_types[0]))
        ? "AL2023_ARM_64_STANDARD"
        : "AL2023_x86_64_STANDARD"
      )

      labels = v.labels
      taints = v.taints

      tags = merge(var.tags, {
        "k8s.io/cluster-autoscaler/enabled"     = "true"
        "k8s.io/cluster-autoscaler/${var.name}" = "owned"
      })
    }
  }

  tags = var.tags
}

# Extra ECR pull permission for the configured repos (defense in depth).
data "aws_iam_policy_document" "extra_ecr_pull" {
  count = length(var.extra_ecr_repository_arns) > 0 ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = var.extra_ecr_repository_arns
  }

  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "extra_ecr_pull" {
  count = length(var.extra_ecr_repository_arns) > 0 ? 1 : 0

  name        = "${var.name}-ecr-pull"
  description = "Allow EKS nodes to pull from the project ECR repos"
  policy      = data.aws_iam_policy_document.extra_ecr_pull[0].json
  tags        = var.tags
}

resource "aws_iam_role_policy_attachment" "extra_ecr_pull" {
  for_each = {
    for k, _ in var.node_groups :
    k => k if length(var.extra_ecr_repository_arns) > 0
  }

  policy_arn = aws_iam_policy.extra_ecr_pull[0].arn
  role       = module.eks.eks_managed_node_groups[each.key].iam_role_name
}
