# ecr

Creates a private ECR repository with:

- AES256 encryption (default).
- `scan_on_push` enabled.
- Lifecycle policy: keep the last `max_image_count` tagged images, expire
  untagged after 1 day.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `name` | string | — | Repository name |
| `image_tag_mutability` | string | `MUTABLE` | `MUTABLE` or `IMMUTABLE` |
| `scan_on_push` | bool | `true` | Scan images on push |
| `max_image_count` | number | `5` | Keep last N tagged images |
| `tags` | map(string) | `{}` | Tags applied to every resource |

## Outputs

| Name | Description |
| --- | --- |
| `repository_url` | Full ECR URL: `<account>.dkr.ecr.<region>.amazonaws.com/<name>` |
| `repository_arn` | ARN of the repo (use it in IAM policies) |
| `repository_name` | Just the name |
