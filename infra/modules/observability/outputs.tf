output "namespace" {
  value = kubernetes_namespace.monitoring.metadata[0].name
}

output "grafana_service_name" {
  value       = "kube-prom-stack-grafana"
  description = "K8s Service name exposing Grafana :80 inside the cluster"
}

output "grafana_admin_password" {
  value       = local.grafana_password
  sensitive   = true
  description = "Initial Grafana admin password (auto-generated if not set)"
}

output "prometheus_service_name" {
  value       = "kube-prom-stack-kube-prom-prometheus"
  description = "K8s Service name exposing Prometheus :9090"
}

output "port_forward_grafana_command" {
  value = "kubectl -n ${var.namespace} port-forward svc/kube-prom-stack-grafana 3000:80"
}

output "port_forward_prometheus_command" {
  value = "kubectl -n ${var.namespace} port-forward svc/kube-prom-stack-kube-prom-prometheus 9090:9090"
}
