variable "project" {
  description = "Project name (used as resource prefix)"
  type        = string
  default     = "llm-chat"
}

variable "environment" {
  description = "Environment name (used in tags + state key)"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.40.0.0/16"
}

variable "worker_az" {
  description = "AZ for worker nodes (single-AZ to save cost)"
  type        = string
  default     = "us-west-2a"
}

variable "extra_az" {
  description = "Second AZ required by EKS control plane"
  type        = string
  default     = "us-west-2b"
}

variable "eks_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.30"
}

# --- Worker node group (runs ChatModel actors) -----------------------------
variable "worker_instance_types" {
  description = "Instance types for the worker MNG (model serving)"
  type        = list(string)
  default     = ["m7g.xlarge"] # 4 vCPU, 16 GiB, Graviton3 sustained
}

variable "worker_capacity_type" {
  type    = string
  default = "ON_DEMAND"
}

variable "worker_min_size" {
  type    = number
  default = 1
}

variable "worker_desired_size" {
  type    = number
  default = 1
}

variable "worker_max_size" {
  type    = number
  default = 3
}

# --- Head node group (runs Ray GCS + Serve proxy only) ---------------------
# Head is non-CPU-intensive (no model). Burstable t4g.large is enough and
# saves ~$70/month vs putting head on m7g.xlarge.
variable "head_instance_types" {
  description = "Instance types for the head MNG (Ray GCS + Serve proxy)"
  type        = list(string)
  default     = ["t4g.large"] # 2 vCPU, 8 GiB, Graviton2 burstable
}

variable "head_capacity_type" {
  type    = string
  default = "ON_DEMAND"
}

variable "image_tag" {
  type    = string
  default = "0.1.0"
}

variable "model_id" {
  description = "HF safetensors repo (label + transformers backend)"
  type        = string
  default     = "Qwen/Qwen3-0.6B"
}

variable "inference_backend" {
  description = "llamacpp (Q4_K_M, recommended) or transformers (bf16 fallback)"
  type        = string
  default     = "llamacpp"
}

variable "gguf_repo_id" {
  description = "HF repo with the GGUF file (llamacpp backend)"
  type        = string
  default     = "Qwen/Qwen3-0.6B-GGUF"
}

variable "gguf_filename" {
  description = "GGUF file name (llamacpp backend)"
  type        = string
  default     = "Qwen3-0.6B-Q4_K_M.gguf"
}

variable "ray_replica_max" {
  type    = number
  default = 3
}

variable "ray_replica_cpus" {
  description = "CPU each Ray Serve replica reserves. With llamacpp Q4 the model is fast enough at 1.5 CPU; bump to 2-3 for transformers bf16."
  type        = number
  default     = 1.5
}

variable "ray_min_replicas" {
  description = "Minimum Ray Serve replicas (2 for HA)"
  type        = number
  default     = 2
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget cap (USD). 0 = skip budget module."
  type        = number
  default     = 100
}

variable "budget_alert_emails" {
  description = "Emails to notify when budget thresholds are crossed"
  type        = list(string)
  default     = []
}

variable "enable_observability" {
  description = "Install kube-prometheus-stack (Prometheus + Grafana)"
  type        = bool
  default     = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password. Empty = auto-generated, retrieve via terraform output."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  description = "Extra tags applied to all resources"
  type        = map(string)
  default     = {}
}
