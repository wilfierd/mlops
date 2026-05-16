# GitHub Actions workflows

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `ci.yml` | PR + push main | terraform fmt/validate/tfsec + python syntax + shellcheck. No AWS access. |
| `deploy.yml` | push main (paths) + manual | OIDC into AWS, build+push image to ECR (linux/arm64), `terraform apply`, roll pods. |
| `destroy.yml` | manual only, with confirmation | `terraform destroy` the env. Guarded by typed confirmation + environment approval. |

## Setup (one-time)

1. **Apply bootstrap with `github_repository` set**:

   ```bash
   cd infra/bootstrap
   # edit terraform.tfvars: github_repository = "your-org/your-repo"
   terraform apply
   ROLE_ARN=$(terraform output -raw gh_deploy_role_arn)
   echo "$ROLE_ARN"
   ```

2. **In GitHub repo Settings**:

   - **Variables → Actions** → add `AWS_DEPLOY_ROLE_ARN` = the role ARN above.
   - **Environments** → create `dev` (and optionally `dev-destroy`):
     - Add required reviewers if you want manual approval before each deploy.
     - Tie to `main` branch only.

3. **Push to main** — `deploy.yml` runs automatically when files under
   `app/`, `Dockerfile`, `requirements.txt`, `infra/`, or this workflow
   directory change.

## OIDC = no long-lived AWS keys

`deploy.yml` and `destroy.yml` use
`aws-actions/configure-aws-credentials@v4` with `role-to-assume`. GitHub
issues a short-lived OIDC token, AWS STS exchanges it for temporary
credentials scoped to the bootstrap-created IAM role. No secrets are
stored anywhere.

## Concurrency

`deploy.yml` uses `concurrency: deploy-<env>` so two pushes to main don't
both run apply at the same time on the same env.

## Skipping image build

Useful when only TF changed:

```text
Actions → deploy → Run workflow → skip_image_build = true
```

This re-applies TF with the same `image_tag = $(git rev-parse --short HEAD)`,
which means it will reference whatever was last pushed for that commit.
