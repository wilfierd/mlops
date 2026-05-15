module "network" {
  source = "../../modules/network"

  name_prefix  = local.name_prefix
  cluster_name = local.name_prefix
  vpc_cidr     = var.vpc_cidr
  worker_az    = var.worker_az
  extra_az     = var.extra_az

  tags = local.tags
}

module "ecr" {
  source = "../../modules/ecr"

  name = "${local.name_prefix}-ray"
  tags = local.tags
}

module "eks" {
  source = "../../modules/eks"

  name                     = local.name_prefix
  kubernetes_version       = var.eks_version
  vpc_id                   = module.network.vpc_id
  control_plane_subnet_ids = module.network.control_plane_subnet_ids
  node_subnet_ids          = module.network.worker_subnet_ids

  node_groups = {
    cpu = {
      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type
      min_size       = var.node_min_size
      desired_size   = var.node_desired_size
      max_size       = var.node_max_size
      labels         = { workload = "ray" }
    }
  }

  extra_ecr_repository_arns = [module.ecr.repository_arn]

  tags = local.tags
}

module "kuberay" {
  source = "../../modules/kuberay"

  service_name = local.name_prefix
  namespace    = "llm-chat"
  image        = "${module.ecr.repository_url}:${var.image_tag}"
  model_id     = var.model_id
  max_replicas = var.ray_replica_max
  replica_cpus = var.ray_replica_cpus

  depends_on = [module.eks]
}
