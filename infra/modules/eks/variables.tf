variable "name" {
  description = "EKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.30"
}

variable "vpc_id" {
  description = "VPC id"
  type        = string
}

variable "control_plane_subnet_ids" {
  description = "Subnets for the EKS control-plane ENIs (>=2 AZ)"
  type        = list(string)
}

variable "node_subnet_ids" {
  description = "Subnets where the MNG places nodes (single-AZ for cost)"
  type        = list(string)
}

variable "node_groups" {
  description = "Managed node groups keyed by name"
  type = map(object({
    instance_types = list(string)
    capacity_type  = optional(string, "ON_DEMAND")
    min_size       = number
    desired_size   = number
    max_size       = number
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
}

variable "extra_ecr_repository_arns" {
  description = "Extra ECR repo ARNs the nodes need pull permission for"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default     = {}
}
