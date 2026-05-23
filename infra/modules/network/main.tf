# Single-AZ workers, dual-AZ control-plane subnets.
# - Public subnets exist in both AZs (EKS API needs >=2 AZ for HA control plane).
# - Private worker subnet only in worker_az -> 1 NAT GW only -> save cost.
# - Lab mode (var.enable_nat_gateway = false + var.workers_in_public_subnet = true):
#   no NAT, workers in public subnet with public IP via IGW. Saves ~$33/mo.
#   Inbound still blocked by node SG; app access via kubectl port-forward.
locals {
  azs = [var.worker_az, var.extra_az]

  public_subnets  = [cidrsubnet(var.vpc_cidr, 4, 0), cidrsubnet(var.vpc_cidr, 4, 1)]
  private_subnets = [cidrsubnet(var.vpc_cidr, 4, 8), cidrsubnet(var.vpc_cidr, 4, 9)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.name_prefix}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  # 1 NAT for worker_az only; private subnet in extra_az has no egress (no nodes there).
  # Lab mode (var.enable_nat_gateway = false): skip NAT entirely, workers must use public subnet
  # tagged for ELB role; outbound traffic goes via IGW directly. Saves ~$33/mo.
  enable_nat_gateway     = var.enable_nat_gateway
  single_nat_gateway     = var.enable_nat_gateway
  one_nat_gateway_per_az = false

  # When workers run in public subnets (lab mode), they need a public IP at boot
  # so kubelet/HF/ECR egress works via IGW without NAT. Inbound is still blocked
  # by the node security group — only the API server / load balancer (if any)
  # is reachable from outside.
  map_public_ip_on_launch = var.workers_in_public_subnet

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = merge(
    {
      "kubernetes.io/role/elb"                    = "1"
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    },
    var.workers_in_public_subnet ? {
      "kubernetes.io/role/internal-elb" = "1"
    } : {},
  )

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = var.tags
}
