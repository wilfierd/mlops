variable "name_prefix" {
  description = "Prefix used in resource names + Name tag"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name (drives subnet kubernetes.io/cluster tag)"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
}

variable "worker_az" {
  description = "AZ where worker subnet lives (single-AZ to save cost)"
  type        = string
}

variable "extra_az" {
  description = "Second AZ required by the EKS control plane subnets"
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default     = {}
}
