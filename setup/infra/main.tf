# Setup: the lab environment.
# Creates the lab resource group and a monthly budget for the subscription. lab-vm.tf adds the lab VM and its network.
# Run it through the course command: ./course up (.\course.ps1 up in PowerShell).

locals {
  tags = {
    course  = "aro-k8s"
    chapter = var.chapter
  }

  # One alert at 50, 80 and 100 percent of the money actually spent, and one when the forecast reaches 100 percent.
  budget_alerts = [
    { threshold = 50, type = "Actual" },
    { threshold = 80, type = "Actual" },
    { threshold = 100, type = "Actual" },
    { threshold = 100, type = "Forecasted" },
  ]
}

data "azurerm_subscription" "current" {}

resource "azurerm_resource_group" "lab" {
  name     = "${var.prefix}-lab-rg"
  location = var.location
  tags     = local.tags
}

# untaggable: Cost Management budgets do not accept tags. The name carries the prefix instead.
resource "azurerm_consumption_budget_subscription" "monthly" {
  name            = "${var.prefix}-monthly-budget"
  subscription_id = data.azurerm_subscription.current.id
  amount          = var.budget_amount
  time_grain      = "Monthly"

  time_period {
    start_date = "${var.budget_start_date}T00:00:00Z"
  }

  dynamic "notification" {
    for_each = local.budget_alerts
    content {
      enabled        = true
      operator       = "GreaterThanOrEqualTo"
      threshold      = notification.value.threshold
      threshold_type = notification.value.type
      contact_emails = [var.alert_email]
    }
  }

  lifecycle {
    # course up passes the first day of the current month. A run in a later month must not move the start of the budget.
    ignore_changes = [time_period]
  }
}
