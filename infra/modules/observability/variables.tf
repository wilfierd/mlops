variable "namespace" {
  description = "Namespace where kube-prometheus-stack is installed"
  type        = string
  default     = "monitoring"
}

variable "chart_version" {
  description = "kube-prometheus-stack Helm chart version"
  type        = string
  default     = "65.1.1"
}

variable "ray_namespace" {
  description = "Namespace where Ray pods live (for ServiceMonitor scoping)"
  type        = string
  default     = "llm-chat"
}

variable "prometheus_retention" {
  description = "How long Prometheus keeps metrics on disk (lab default 6h)"
  type        = string
  default     = "6h"
}

variable "prometheus_memory" {
  description = "Memory request for Prometheus pod"
  type        = string
  default     = "512Mi"
}

variable "grafana_admin_password" {
  description = "Grafana admin password. If empty, a random one is generated and exposed via output."
  type        = string
  default     = ""
  sensitive   = true
}

variable "persist_grafana" {
  description = "Use a PVC for Grafana storage (otherwise ephemeral)"
  type        = bool
  default     = false
}

variable "ops_node_selector" {
  description = "Optional nodeSelector for Prometheus and Grafana pods (e.g. {node-type = \"ops\"}). Empty map means no selector."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags (unused on K8s resources but kept for module-uniformity)"
  type        = map(string)
  default     = {}
}
