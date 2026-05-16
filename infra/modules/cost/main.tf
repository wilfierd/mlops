resource "aws_budgets_budget" "monthly" {
  name              = "${var.name}-monthly"
  budget_type       = "COST"
  limit_amount      = tostring(var.monthly_budget_usd)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2025-01-01_00:00"

  # Scope budget to resources tagged with Project=<name>. Requires the user to
  # activate the "Project" cost allocation tag in Billing console once.
  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$${var.name}"]
  }

  dynamic "notification" {
    for_each = length(var.alert_emails) > 0 ? var.alert_thresholds : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value >= 100 ? "FORECASTED" : "ACTUAL"
      subscriber_email_addresses = var.alert_emails
    }
  }
}
