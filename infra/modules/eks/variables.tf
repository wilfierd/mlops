variable "name" {
  description = "EKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Default 1.34 — currently in standard support (no extended-support fee). Bump in lockstep with AWS deprecation calendar."
  type        = string
  default     = "1.34"
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
    instance_types        = list(string)
    capacity_type         = optional(string, "ON_DEMAND")
    min_size              = number
    desired_size          = number
    max_size              = number
    labels                = optional(map(string), {})
    block_device_mappings = optional(any, {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
    # Optional override; default is auto-detected from instance_types[0]
    # (ARM if starts with t4g/m6g/m7g/m8g/c6g/c7g/r6g/r7g, else x86).
    ami_type = optional(string, "")
  }))
}

variable "extra_ecr_repository_arns" {
  description = "Extra ECR repo ARNs the nodes need pull permission for"
  type        = list(string)
  default     = []
}

variable "enable_ebs_csi_driver" {
  description = "Install the aws-ebs-csi-driver EKS addon with an IRSA role. Required for binding PVs to pre-existing EBS volumes (persistent stack)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default     = {}
}
