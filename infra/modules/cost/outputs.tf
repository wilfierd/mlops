output "budget_name" {
  value = aws_budgets_budget.monthly.name
}

output "budget_arn" {
  value = aws_budgets_budget.monthly.arn
}
