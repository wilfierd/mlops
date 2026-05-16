variable "name" {
  description = "Budget name + Project tag filter value"
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly budget cap in USD"
  type        = number
  default     = 100
}

variable "alert_thresholds" {
  description = "Notification thresholds (as % of budget)"
  type        = list(number)
  default     = [50, 80, 100]
}

variable "alert_emails" {
  description = "Emails to notify when thresholds cross. Empty = no notifications."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default     = {}
}
