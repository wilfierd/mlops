###############################################################################
# PERSISTENT stack — VPC, ECR, S3, EBS, IAM/OIDC.
#
# CONVENTION (HARD RULE):
#   persistent/ = DO NOT destroy in daily workflow. If you run
#                   terraform -chdir=infra/environments/dev/persistent destroy
#                 you LOSE ECR images, S3 data, Qdrant vectors, and the LLM
#                 model cache. All four critical resources are guarded with
#                 `lifecycle { prevent_destroy = true }` to make this an error.
#   ephemeral/  = destroy/apply freely (cluster lifecycle).
#
# To intentionally destroy a persistent resource (rare — only when migrating
# accounts/regions): remove the `prevent_destroy` block from the relevant
# resource, `terraform apply`, then `destroy`.
#
# Network posture (lab mode, see terraform.tfvars):
#   enable_nat_gateway       = false   # no $33/mo NAT
#   workers_in_public_subnet = true    # workers run in public subnet with
#   map_public_ip_on_launch  = true    #  public IP, outbound via IGW
#   Inbound still blocked by SGs; app access via `kubectl port-forward`.
#   Production should flip to private subnet + NAT or VPC endpoints.
#
# Cost when idle (no ephemeral cluster up): ~$3–5/month
#   - EBS qdrant (10 GiB gp3)         $0.80/mo
#   - EBS llm-cache (20 GiB gp3)      $1.60/mo
#   - S3 (~10 GiB seed + snapshots)   $0.25/mo
#   - ECR (~1.5 GiB app images)       $0.15/mo
#   - VPC + IGW + OIDC                $0
###############################################################################

data "aws_caller_identity" "current" {}

###############################################################################
# 1. VPC (no NAT in lab mode — workers run in public subnet for HF/ECR egress)
###############################################################################
module "network" {
  source = "../../../modules/network"

  name_prefix              = local.name_prefix
  cluster_name             = local.name_prefix
  vpc_cidr                 = var.vpc_cidr
  worker_az                = var.worker_az
  extra_az                 = var.extra_az
  enable_nat_gateway       = var.enable_nat_gateway
  workers_in_public_subnet = !var.enable_nat_gateway

  tags = local.tags
}

###############################################################################
# 2. ECR — app proxy image (FastAPI + Ray Serve + Embedder). vLLM uses upstream
#    image so we don't push a copy.
###############################################################################
module "ecr_app" {
  source = "../../../modules/ecr"

  name         = "${local.name_prefix}-app"
  force_delete = var.ecr_force_delete
  tags         = local.tags
}

###############################################################################
# 3. S3 — raw docs + Qdrant snapshots
###############################################################################
resource "aws_s3_bucket" "data" {
  bucket = "${local.name_prefix}-data-${data.aws_caller_identity.current.account_id}"
  tags   = local.tags

  # SAFETY: do not destroy by accident.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  # Old snapshot versions: expire after 30 days. Keeps disaster recovery cheap.
  rule {
    id     = "expire-old-snapshot-versions"
    status = "Enabled"

    filter {
      prefix = "qdrant-backup/"
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

###############################################################################
# 4. EBS volumes — Qdrant data + LLM HF cache.
#
# Pre-created here so the ephemeral stack can bind a PV to volumeHandle and the
# data survives `terraform destroy` of the ephemeral cluster.
###############################################################################
resource "aws_ebs_volume" "qdrant_data" {
  availability_zone = var.worker_az
  size              = var.qdrant_volume_size_gib
  type              = "gp3"
  encrypted         = true

  tags = merge(local.tags, {
    Name = "${local.name_prefix}-qdrant-data"
    Role = "qdrant-storage"
  })

  lifecycle {
    prevent_destroy = true
    # Ignore size drift if user resizes online via `aws ec2 modify-volume`.
    ignore_changes = [size]
  }
}

resource "aws_ebs_volume" "llm_cache" {
  availability_zone = var.worker_az
  size              = var.llm_cache_volume_size_gib
  type              = "gp3"
  encrypted         = true

  tags = merge(local.tags, {
    Name = "${local.name_prefix}-llm-cache"
    Role = "model-cache"
  })

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [size]
  }
}

###############################################################################
# 5. IAM OIDC provider — for GitHub Actions to assume role for cluster lifecycle
#    (terraform apply/destroy on ephemeral stack, push to ECR).
#
# Only created when var.github_repo is set.
###############################################################################
data "tls_certificate" "github" {
  count = var.github_repo == "" ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.github_repo == "" ? 0 : 1

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github[0].certificates[0].sha1_fingerprint]

  tags = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_policy_document" "github_assume" {
  count = var.github_repo == "" ? 0 : 1

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  count              = var.github_repo == "" ? 0 : 1
  name               = "${local.name_prefix}-gh-actions"
  assume_role_policy = data.aws_iam_policy_document.github_assume[0].json
  tags               = local.tags
}

# Broad permissions for lab/dev: cluster lifecycle + ECR push. Trim for prod.
resource "aws_iam_role_policy_attachment" "github_admin" {
  count      = var.github_repo == "" ? 0 : 1
  role       = aws_iam_role.github_actions[0].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
