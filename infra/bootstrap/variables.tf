variable "project" {
  description = "Used to namespace bootstrap resources (bucket + table + role names)"
  type        = string
  default     = "llm-chat"
}

variable "region" {
  description = "AWS region for the state bucket + lock table"
  type        = string
  default     = "us-west-2"
}

# Set this to your GitHub repo (e.g. "your-org/your-repo") to allow the
# corresponding GitHub Actions to assume the deploy role via OIDC.
# Leave empty to skip creating the OIDC provider + role.
variable "github_repository" {
  description = "GitHub repo (org/repo) allowed to assume the deploy role via OIDC. Empty = skip OIDC."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all bootstrap resources"
  type        = map(string)
  default = {
    Project   = "llm-chat"
    ManagedBy = "terraform"
    Stack     = "infra/bootstrap"
  }
}
