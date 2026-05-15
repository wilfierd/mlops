output "namespace" {
  value = var.namespace
}

output "operator_namespace" {
  value = var.operator_namespace
}

output "service_name" {
  value       = "${var.service_name}-serve-svc"
  description = "K8s Service name that exposes Ray Serve HTTP (8000)"
}
