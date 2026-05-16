# bootstrap

One-time stack that has to be applied **before** any `environments/<env>`.
Creates:

- **S3 bucket** for Terraform remote state (versioned, encrypted, public-blocked).
- **DynamoDB table** for state locking.
- **GitHub OIDC provider + IAM role** that GitHub Actions assumes via OIDC
  (created only when `github_repository` is set).

Local state used here on purpose — we can't store bootstrap's state in the
bucket it's creating.

## Usage

```bash
cd infra/bootstrap

# Edit terraform.tfvars.example, then:
terraform init
terraform apply

# Print backend snippet for the dev env
terraform output -raw backend_config
```

Paste the `backend_config` output into `environments/dev/backend.tf`
(replace `<env>` with `dev`), then:

```bash
cd ../environments/dev
terraform init -migrate-state
# Answer "yes" when prompted to copy local state -> S3
```

For each new environment (`staging`, `prod`, ...), reuse the same bucket+table
with a different `key` (`mlops/llm-chat/staging/terraform.tfstate`, etc).

## GitHub Actions OIDC (optional)

Set `github_repository = "your-org/your-repo"` in tfvars and re-apply. The
output `gh_deploy_role_arn` is what you paste into the GitHub Actions
workflow's `role-to-assume`. No long-lived AWS keys needed.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `project` | string | `llm-chat` | Prefix for bucket/table/role names |
| `region` | string | `us-west-2` | Region for bucket + table |
| `github_repository` | string | `""` | `org/repo` for OIDC. Empty = skip OIDC. |
| `tags` | map(string) | see code | Tags on all bootstrap resources |

## Outputs

| Name | Description |
| --- | --- |
| `state_bucket` | S3 bucket holding TF state |
| `lock_table` | DDB table for locking |
| `region` | Region |
| `gh_deploy_role_arn` | OIDC role ARN (or empty) |
| `backend_config` | Copy-paste snippet for env `backend.tf` |
