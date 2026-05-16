# cost

Creates an AWS Budget that tracks monthly spend filtered by the `Project` tag
and sends email alerts at configurable thresholds.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `name` | string | — | Budget name AND `Project` tag value to filter on |
| `monthly_budget_usd` | number | `100` | Cap in USD |
| `alert_thresholds` | list(number) | `[50, 80, 100]` | % of budget to alert at |
| `alert_emails` | list(string) | `[]` | Emails to notify (empty = no notifications) |
| `tags` | map(string) | `{}` | (currently unused; budget itself isn't tagged) |

## Outputs

| Name | Description |
| --- | --- |
| `budget_name` | Final budget name |
| `budget_arn` | Budget ARN |

## Cost allocation tag activation

The `cost_filter` uses `TagKeyValue = user:Project$<name>`. For Budget to actually
filter on this tag, the **Project** cost allocation tag must be activated in
the AWS Billing console once per account:

```text
Billing → Cost allocation tags → User-defined cost allocation tags
  → Find "Project" → Activate
```

Activation takes 24h to propagate but is one-time per account. Until then the
budget tracks total account spend.

## What gets tagged

The root `environments/dev/providers.tf` sets:

```hcl
provider "aws" {
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      ...
    }
  }
}
```

So every AWS resource created by this stack carries `Project=<project>` and is
included in the filter automatically.
