###############################################################################
# Read persistent stack outputs (VPC ids, EBS volume ids, ECR, S3 bucket).
###############################################################################
data "aws_caller_identity" "current" {}

locals {
  # Default the state bucket to the bootstrap pattern when not overridden.
  effective_state_bucket = (
    var.persistent_state_bucket != "" ? var.persistent_state_bucket :
    "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
  )
}

data "terraform_remote_state" "persistent" {
  backend = "s3"
  config = {
    bucket = local.effective_state_bucket
    key    = var.persistent_state_key
    region = var.region
  }
}

locals {
  # Short aliases — used throughout main.tf / k8s.tf.
  name_prefix     = data.terraform_remote_state.persistent.outputs.name_prefix
  vpc_id          = data.terraform_remote_state.persistent.outputs.vpc_id
  cp_subnet_ids   = data.terraform_remote_state.persistent.outputs.control_plane_subnet_ids
  node_subnet_ids = data.terraform_remote_state.persistent.outputs.node_subnet_ids
  worker_az       = data.terraform_remote_state.persistent.outputs.worker_az

  ecr_app_url         = data.terraform_remote_state.persistent.outputs.ecr_app_url
  ecr_app_arn         = data.terraform_remote_state.persistent.outputs.ecr_app_arn
  data_bucket         = data.terraform_remote_state.persistent.outputs.data_bucket
  qdrant_volume_id    = data.terraform_remote_state.persistent.outputs.qdrant_volume_id
  qdrant_volume_size  = data.terraform_remote_state.persistent.outputs.qdrant_volume_size_gib
  llm_cache_volume_id = data.terraform_remote_state.persistent.outputs.llm_cache_volume_id
  llm_cache_size      = data.terraform_remote_state.persistent.outputs.llm_cache_volume_size_gib

  tags = merge({
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Stack       = "infra/environments/dev/ephemeral"
  }, var.tags)
}
