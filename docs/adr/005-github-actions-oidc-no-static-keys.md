# 005 — GitHub Actions OIDC trust, not stored AWS keys

Status: accepted
Date: 2026-05-15

## Context

CI/CD needs to call AWS APIs (push to ECR, run Terraform). The two patterns:

1. Long-lived `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` in GitHub
   Secrets. Simple, works everywhere. Bad: keys live forever, rotation is
   manual, key leakage is total compromise.

2. GitHub OIDC: the runner gets a short-lived OIDC ID token from GitHub,
   AWS STS exchanges it for ~1-hour credentials scoped to a specific IAM
   role. No static secret stored anywhere.

## Decision

Use GitHub OIDC. The OIDC provider + deploy role are managed by
`infra/bootstrap` and trust limited to a specific `<org>/<repo>` via the
`token.actions.githubusercontent.com:sub` condition.

## Consequences

- Zero static AWS keys in the GitHub repo. Even a fully compromised PR
  cannot exfiltrate persistent credentials.
- Lab uses `AdministratorAccess` on the role for speed. Real prod requires
  a least-privilege policy — TODO list in `bootstrap/main.tf` IAM block.
- The trust condition `repo:<org>/<repo>:*` allows any branch in the repo.
  Stricter version is `repo:<org>/<repo>:ref:refs/heads/main` if we want
  PRs from forks to be locked out.
- Requires the `id-token: write` permission in every workflow job that
  assumes the role — easy to forget; documented in `.github/workflows/README.md`.
