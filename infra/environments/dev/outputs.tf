output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "image_tag" {
  value = var.image_tag
}

output "model_id" {
  value = var.model_id
}

output "kubeconfig_command" {
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
  description = "Run this to wire kubectl to the new cluster"
}

output "port_forward_command" {
  value       = "kubectl -n ${module.kuberay.namespace} port-forward svc/${module.kuberay.service_name} 8000:8000"
  description = "Run this for local access to the chat UI"
}

output "ecr_login_command" {
  value       = "aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${split("/", module.ecr.repository_url)[0]}"
  description = "Run this before docker push"
}

output "grafana_port_forward_command" {
  value       = var.enable_observability ? module.observability[0].port_forward_grafana_command : "(observability disabled)"
  description = "Open Grafana locally"
}

output "grafana_admin_password" {
  value       = var.enable_observability ? module.observability[0].grafana_admin_password : ""
  sensitive   = true
  description = "Grafana admin password (auto-generated unless overridden)"
}

output "prometheus_port_forward_command" {
  value       = var.enable_observability ? module.observability[0].port_forward_prometheus_command : "(observability disabled)"
  description = "Open Prometheus locally"
}
