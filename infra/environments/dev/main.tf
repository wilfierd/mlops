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

  # Two node groups so head + worker can have different instance classes.
  # Head doesn't run model => burstable t4g.large is plenty + cheap.
  # Worker runs Ray actors => sustained Graviton3 to avoid throttle.
  node_groups = {
    head = {
      instance_types = var.head_instance_types
      capacity_type  = var.head_capacity_type
      min_size       = 1
      desired_size   = 1
      max_size       = 1
      labels         = { "ray.io/node-type" = "head" }
      taints = [{
        key    = "ray-role"
        value  = "head"
        effect = "NO_SCHEDULE"
      }]
    }
    worker = {
      instance_types = var.worker_instance_types
      capacity_type  = var.worker_capacity_type
      min_size       = var.worker_min_size
      desired_size   = var.worker_desired_size
      max_size       = var.worker_max_size
      labels         = { "ray.io/node-type" = "worker" }
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

  # Backend wiring — defaults to llamacpp + Q4_K_M for fast CPU inference.
  inference_backend = var.inference_backend
  model_id          = var.model_id
  gguf_repo_id      = var.gguf_repo_id
  gguf_filename     = var.gguf_filename

  # Serve autoscale (actor counts; pod count derived in kuberay module).
  min_replicas   = var.ray_min_replicas
  max_replicas   = var.ray_replica_max
  replica_cpus   = var.ray_replica_cpus
  actors_per_pod = var.ray_actors_per_pod

  depends_on = [module.eks]
}

module "cost" {
  count  = var.monthly_budget_usd > 0 ? 1 : 0
  source = "../../modules/cost"

  name               = var.project
  monthly_budget_usd = var.monthly_budget_usd
  alert_emails       = var.budget_alert_emails

  tags = local.tags
}

module "observability" {
  count  = var.enable_observability ? 1 : 0
  source = "../../modules/observability"

  ray_namespace          = module.kuberay.namespace
  grafana_admin_password = var.grafana_admin_password

  tags = local.tags

  depends_on = [module.kuberay]
}
