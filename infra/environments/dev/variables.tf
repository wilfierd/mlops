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

variable "node_instance_types" {
  type    = list(string)
  default = ["m7g.xlarge"]
}

variable "node_capacity_type" {
  type    = string
  default = "ON_DEMAND"
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "image_tag" {
  type    = string
  default = "0.1.0"
}

variable "model_id" {
  type    = string
  default = "Qwen/Qwen3-0.6B"
}

variable "ray_replica_max" {
  type    = number
  default = 3
}

variable "ray_replica_cpus" {
  type    = number
  default = 3
}

variable "tags" {
  description = "Extra tags applied to all resources"
  type        = map(string)
  default     = {}
}
