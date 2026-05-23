###############################################################################
# Network — consumed by ephemeral stack via terraform_remote_state
###############################################################################
output "vpc_id" {
  value = module.network.vpc_id
}

output "vpc_cidr" {
  value = module.network.vpc_cidr
}

output "control_plane_subnet_ids" {
  value       = module.network.control_plane_subnet_ids
  description = "Pass to EKS control_plane_subnet_ids"
}

# In lab mode (no NAT), workers run in public subnet. The ephemeral stack picks
# either worker_subnet_ids (private) or public_subnet_ids accordingly.
output "worker_subnet_ids" {
  value       = module.network.worker_subnet_ids
  description = "Private worker subnet (1 AZ). Empty/unused when running lab-mode in public subnet."
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "worker_az" {
  value       = module.network.worker_az
  description = "The single AZ where worker nodes + EBS volumes live"
}

output "nat_gateway_enabled" {
  value = var.enable_nat_gateway
}

# Routed convenience — pick the right subnet for the node MNG based on NAT
# posture. Lab mode (no NAT) → public subnet in worker_az. With NAT → private
# subnet in worker_az. Always exactly 1 subnet ID to keep EBS AZ-pinning sane.
output "node_subnet_ids" {
  value = var.enable_nat_gateway ? (
    module.network.worker_subnet_ids
    ) : (
    [module.network.public_subnet_ids[0]] # public_subnet_ids[0] is worker_az by network module convention
  )
  description = "Subnet IDs where the EKS managed node groups place nodes. Single AZ to match EBS volume placement."
}

###############################################################################
# ECR
###############################################################################
output "ecr_app_url" {
  value       = module.ecr_app.repository_url
  description = "ECR repo URL for the FastAPI/Embedder/Ray Serve app image"
}

output "ecr_app_arn" {
  value = module.ecr_app.repository_arn
}

###############################################################################
# S3
###############################################################################
output "data_bucket" {
  value       = aws_s3_bucket.data.id
  description = "S3 bucket for raw docs + Qdrant snapshots"
}

output "data_bucket_arn" {
  value = aws_s3_bucket.data.arn
}

###############################################################################
# EBS — these volume IDs are what the ephemeral PV manifests bind to via
# csi.volumeHandle. Treat as load-bearing — destroying them loses data.
###############################################################################
output "qdrant_volume_id" {
  value       = aws_ebs_volume.qdrant_data.id
  description = "Bind to PV qdrant-data-pv in ephemeral stack"
}

output "qdrant_volume_size_gib" {
  value = aws_ebs_volume.qdrant_data.size
}

output "llm_cache_volume_id" {
  value       = aws_ebs_volume.llm_cache.id
  description = "Bind to PV llm-cache-pv in ephemeral stack (HF model cache for vllm-openai)"
}

output "llm_cache_volume_size_gib" {
  value = aws_ebs_volume.llm_cache.size
}

###############################################################################
# IAM OIDC — only present when var.github_repo is set
###############################################################################
output "github_actions_role_arn" {
  value       = try(aws_iam_role.github_actions[0].arn, null)
  description = "Assume this role from GitHub Actions for cluster lifecycle workflows"
}

###############################################################################
# Name prefix — used by ephemeral stack to name the EKS cluster + node groups.
###############################################################################
output "name_prefix" {
  value = local.name_prefix
}

output "region" {
  value = var.region
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
