# Setup: Terraform and provider versions, state backend and provider settings.
# Run it through ./course up (.\course.ps1 up in PowerShell), which fills in the backend and every variable.

terraform {
  required_version = ">= 1.17.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.14"
    }
  }

  # The state lives in a blob of the storage account that course up creates before Terraform runs.
  # course up passes the account, the container and the key with terraform init -backend-config.
  backend "azurerm" {}
}

provider "azurerm" {
  # course up registers the resource providers of the course itself, so Terraform does not try to.
  resource_provider_registrations = "none"

  features {
    resource_group {
      # course destroy deletes the lab resource group even if a lab left a resource in it.
      prevent_deletion_if_contains_resources = false
    }
  }
}
