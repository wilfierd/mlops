###############################################################################
# Cluster info — feed to kubectl, CI workflows, app deploys.
###############################################################################
output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value     = module.eks.cluster_endpoint
  sensitive = true
}

output "cluster_oidc_provider_arn" {
  value = module.eks.cluster_oidc_provider_arn
}

###############################################################################
# Node group IAM role ARNs — handy when adding extra policies (S3 access, etc.)
###############################################################################
output "node_role_arns" {
  value = module.eks.node_iam_role_arns
}

###############################################################################
# Pass-through from persistent — convenient for `terraform output` in one place.
###############################################################################
output "namespace" {
  value = var.kubernetes_namespace
}

output "ecr_app_url" {
  value = local.ecr_app_url
}

output "data_bucket" {
  value = local.data_bucket
}

output "qdrant_volume_id" {
  value = local.qdrant_volume_id
}

output "llm_cache_volume_id" {
  value = local.llm_cache_volume_id
}

###############################################################################
# Quickstart commands — printed after apply, copy/paste to verify.
###############################################################################
output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "gpu_check_command" {
  value = "kubectl get nodes -l node-type=gpu-worker -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.status.allocatable.nvidia\\.com/gpu}{\"\\n\"}{end}'"
}
