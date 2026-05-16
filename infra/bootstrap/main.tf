provider "aws" {
  region = var.region
  default_tags {
    tags = var.tags
  }
}

data "aws_caller_identity" "this" {}

locals {
  account_id = data.aws_caller_identity.this.account_id
  bucket     = "${var.project}-tfstate-${local.account_id}"
  table      = "${var.project}-tflock"
}

# -----------------------------------------------------------------------------
# Remote state bucket + DDB lock table
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket

  # Lab convenience: allow destroy even with state objects in it. Flip to
  # `false` for real prod state.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tflock" {
  name         = local.table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# -----------------------------------------------------------------------------
# GitHub Actions OIDC trust (created only when var.github_repository is set)
# -----------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count = var.github_repository != "" ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # GitHub's root CA fingerprint. Stable for years but verify on rotation.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

data "aws_iam_policy_document" "gh_assume" {
  count = var.github_repository != "" ? 1 : 0

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
      values   = ["repo:${var.github_repository}:*"]
    }
  }
}

resource "aws_iam_role" "gh_deploy" {
  count = var.github_repository != "" ? 1 : 0

  name               = "${var.project}-gh-deploy"
  assume_role_policy = data.aws_iam_policy_document.gh_assume[0].json
  description        = "Assumed by GitHub Actions workflow in ${var.github_repository} via OIDC"
}

# Lab scope = full AWS access. For real prod, narrow to specific actions
# (eks:*, ecr:*, s3:*tfstate*, dynamodb:*tflock*, iam: scoped, ...).
resource "aws_iam_role_policy_attachment" "gh_admin" {
  count = var.github_repository != "" ? 1 : 0

  role       = aws_iam_role.gh_deploy[0].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
