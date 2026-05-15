output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_ca_data" {
  value       = module.eks.cluster_certificate_authority_data
  description = "Base64 cluster CA"
}

output "cluster_oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "cluster_oidc_provider_url" {
  value = module.eks.oidc_provider
}

output "node_iam_role_arns" {
  value = {
    for k, ng in module.eks.eks_managed_node_groups : k => ng.iam_role_arn
  }
}
