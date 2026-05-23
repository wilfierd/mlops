variable "service_name" {
  description = "RayService metadata.name (becomes serve service prefix)"
  type        = string
  default     = "llm-chat"
}

variable "namespace" {
  description = "Namespace for the RayService"
  type        = string
  default     = "llm-chat"
}

variable "operator_namespace" {
  description = "Namespace for the KubeRay operator"
  type        = string
  default     = "kuberay-system"
}

variable "operator_chart_version" {
  description = "kuberay-operator Helm chart version"
  type        = string
  default     = "1.6.1"
}

variable "ray_version" {
  description = "Ray runtime version in the image"
  type        = string
  default     = "2.55.1"
}

variable "image" {
  description = "Container image for the Ray head app pod (ECR URL + tag)"
  type        = string
}

variable "head_cpu_request" {
  type    = string
  default = "1200m"
}

variable "head_cpu_limit" {
  type    = string
  default = "1800m"
}

variable "head_memory_request" {
  type    = string
  default = "3Gi"
}

variable "head_memory_limit" {
  type    = string
  default = "5Gi"
}
