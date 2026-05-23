variable "project" {
  description = "Project tag / name prefix (lowercase, no spaces)"
  type        = string
  default     = "llm-chat"
}

variable "environment" {
  description = "Environment short name (dev/staging/prod)"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "vpc_cidr" {
  description = "VPC CIDR for the persistent VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "worker_az" {
  description = "Single AZ where worker nodes + matching EBS volumes will live. Lock once; changing AZ after EBS create requires snapshot+restore."
  type        = string
  default     = "us-west-2a"
}

variable "extra_az" {
  description = "Second AZ for the EKS control plane public subnets (no nodes will run here)"
  type        = string
  default     = "us-west-2b"
}

variable "enable_nat_gateway" {
  description = "Lab default: false (saves ~$33/mo). Workers run in public subnet via IGW for HF/ECR egress."
  type        = bool
  default     = false
}

variable "qdrant_volume_size_gib" {
  description = "EBS volume size for Qdrant data (Retain reclaim across cluster destroy)"
  type        = number
  default     = 10
}

variable "llm_cache_volume_size_gib" {
  description = "EBS volume size for HF model cache (Qwen2.5-7B-AWQ ~5GB, plus tokenizers + future models)"
  type        = number
  default     = 20
}

variable "github_repo" {
  description = "GitHub org/repo for OIDC trust (e.g. 'octocat/mlops'). Leave empty to skip OIDC provider/role."
  type        = string
  default     = ""
}

variable "ecr_force_delete" {
  description = "Allow ECR repo destroy even if images remain. Keep false in production."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Extra tags merged into local.tags"
  type        = map(string)
  default     = {}
}
