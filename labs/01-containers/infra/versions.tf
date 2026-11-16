# Lab 01: Terraform and provider versions, state backend and provider settings.
# Run it on the lab VM through course start 01, which fills in the backend and every variable.

terraform {
  required_version = ">= 1.17.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.14"
    }
  }

  # Same storage account as the setup, with its own key. setup.sh passes the details with terraform init -backend-config.
  backend "azurerm" {}
}

provider "azurerm" {
  # The lab VM's identity may only change the lab resource group, so Terraform must not register resource providers.
  # course up registered every one the course needs.
  resource_provider_registrations = "none"

  features {}
}
