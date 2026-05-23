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

variable "enable_nat_gateway" {
  description = "Create a NAT gateway for private subnets. Set false for lab mode (saves ~$33/mo; workloads must run in public subnet OR rely on VPC endpoints)."
  type        = bool
  default     = true
}

variable "workers_in_public_subnet" {
  description = "Lab-mode trade-off: when true, persistent stack still tags PUBLIC subnets with kubernetes.io/role/internal-elb so worker MNGs in the ephemeral stack can run in public subnets. Combine with enable_nat_gateway=false to avoid NAT cost."
  type        = bool
  default     = false
}
