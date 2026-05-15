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
  description = "Container image for Ray head/worker (ECR URL + tag)"
  type        = string
}

variable "model_id" {
  description = "Hugging Face model id"
  type        = string
}

variable "model_dtype" {
  description = "PyTorch dtype (bfloat16 recommended on x86 CPU)"
  type        = string
  default     = "bfloat16"
}

variable "max_replicas" {
  description = "Ray Serve max replicas"
  type        = number
  default     = 3
}

variable "min_replicas" {
  type    = number
  default = 1
}

variable "replica_cpus" {
  description = "CPU each Ray Serve replica reserves"
  type        = number
  default     = 3
}

variable "head_cpu_request" {
  type    = string
  default = "1"
}

variable "head_cpu_limit" {
  type    = string
  default = "2"
}

variable "head_memory_request" {
  type    = string
  default = "2Gi"
}

variable "head_memory_limit" {
  type    = string
  default = "3Gi"
}

variable "worker_cpu_request" {
  type    = string
  default = "3"
}

variable "worker_cpu_limit" {
  type    = string
  default = "3500m"
}

variable "worker_memory_request" {
  type    = string
  default = "3Gi"
}

variable "worker_memory_limit" {
  type    = string
  default = "5Gi"
}
