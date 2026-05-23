###############################################################################
# AWS — region inherited from var.region.
###############################################################################
provider "aws" {
  region = var.region
  default_tags {
    tags = local.tags
  }
}

###############################################################################
# K8s / Helm / kubectl — wired to the freshly-created EKS cluster.
#
# We deliberately DO NOT use data.aws_eks_cluster_auth: the token it returns is
# short-lived and `terraform apply` often outlives it (EKS control-plane create
# can take 15+ min). Using `exec` makes every K8s API call fetch a fresh token
# via `aws eks get-token`, so the providers can't run out of auth mid-apply.
###############################################################################
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.region,
    ]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", module.eks.cluster_name,
        "--region", var.region,
      ]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_data)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.region,
    ]
  }
}
