output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr_block
}

# Pass to EKS control_plane_subnet_ids: public subnets in both AZs.
output "control_plane_subnet_ids" {
  value       = module.vpc.public_subnets
  description = "Public subnets (2 AZ) for EKS control plane ENIs"
}

# Pass to EKS node_subnet_ids: private subnet in worker_az only.
output "worker_subnet_ids" {
  value       = slice(module.vpc.private_subnets, 0, 1)
  description = "Private subnet (1 AZ) for the worker MNG"
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}
