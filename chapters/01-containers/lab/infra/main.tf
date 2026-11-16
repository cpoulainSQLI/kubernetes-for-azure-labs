# Chapter 1: a Basic container registry in the lab resource group.
# Deployed from the lab VM by chapters/01-containers/lab/setup.sh and deleted by teardown.sh.

variable "prefix" {
  description = "Short name used in resource names: lowercase letters and digits only."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,11}$", var.prefix))
    error_message = "The prefix must be 3 to 12 lowercase letters or digits and start with a letter."
  }
}

variable "resource_group_name" {
  description = "The lab resource group created in chapter 0."
  type        = string
}

variable "chapter" {
  description = "Chapter that owns this resource. Used in the chapter tag."
  type        = string
  default     = "01"
}

locals {
  tags = {
    course  = "aro-k8s"
    chapter = var.chapter
  }
}

data "azurerm_resource_group" "lab" {
  name = var.resource_group_name
}

# Registry names are global, so a hash of the resource group ID keeps them unique.
resource "azurerm_container_registry" "chapter" {
  name                = "${var.prefix}acr${substr(sha1(data.azurerm_resource_group.lab.id), 0, 13)}"
  location            = data.azurerm_resource_group.lab.location
  resource_group_name = data.azurerm_resource_group.lab.name
  sku                 = "Basic"
  # Sign-in goes through Microsoft Entra ID (az acr login), never through a shared admin password.
  admin_enabled                 = false
  public_network_access_enabled = true
  tags                          = local.tags
}

output "registry_name" {
  description = "Name of the registry."
  value       = azurerm_container_registry.chapter.name
}

output "login_server" {
  description = "Login server of the registry, used in image names."
  value       = azurerm_container_registry.chapter.login_server
}
