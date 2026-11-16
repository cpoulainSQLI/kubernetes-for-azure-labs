# Chapter 1: Terraform and provider versions, state backend and provider settings.
# Run it on the lab VM through chapters/01-containers/lab/setup.sh, which fills in the backend and every variable.

terraform {
  required_version = ">= 1.17.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.14"
    }
  }

  # Same storage account as chapter 0, with its own key. setup passes the details with terraform init -backend-config.
  backend "azurerm" {}
}

provider "azurerm" {
  # The lab VM's identity may only change the lab resource group, so Terraform must not register resource providers.
  # Chapter 0 setup registered every one the course needs.
  resource_provider_registrations = "none"

  features {}
}
