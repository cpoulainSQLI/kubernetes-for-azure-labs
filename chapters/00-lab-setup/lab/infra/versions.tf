# Chapter 0: Terraform and provider versions, state backend and provider settings.
# Run it through chapters/00-lab-setup/lab/setup.sh (or setup.ps1), which fills in the backend and every variable.

terraform {
  required_version = ">= 1.17.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.14"
    }
  }

  # The state lives in a blob of the storage account that setup creates before Terraform runs.
  # setup passes the account, the container and the key with terraform init -backend-config.
  backend "azurerm" {}
}

provider "azurerm" {
  # setup registers the resource providers of the course itself, so Terraform does not try to.
  resource_provider_registrations = "none"

  features {
    resource_group {
      # Teardown deletes the lab resource group even if a later chapter left a resource in it.
      prevent_deletion_if_contains_resources = false
    }
  }
}
