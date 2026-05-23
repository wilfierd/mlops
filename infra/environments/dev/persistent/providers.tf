locals {
  name_prefix = "${var.project}-${var.environment}"

  tags = merge({
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Stack       = "infra/environments/dev/persistent"
  }, var.tags)
}

# Persistent stack only needs AWS — no K8s/Helm here (the cluster lives in ephemeral/).
provider "aws" {
  region = var.region
  default_tags {
    tags = local.tags
  }
}
