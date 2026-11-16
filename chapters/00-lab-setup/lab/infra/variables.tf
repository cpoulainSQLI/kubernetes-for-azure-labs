# Chapter 0: input variables. setup fills in every one of them from .env, through TF_VAR_ environment variables.

variable "prefix" {
  description = "Short name used in every resource name."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,11}$", var.prefix))
    error_message = "The prefix must be 3 to 12 lowercase letters or digits and start with a letter."
  }
}

variable "location" {
  description = "Azure region for the lab."
  type        = string
}

variable "chapter" {
  description = "Chapter that owns these resources. Used in the chapter tag."
  type        = string
  default     = "00"
}

variable "budget_amount" {
  description = "Monthly budget amount in the billing currency of the subscription."
  type        = number

  validation {
    condition     = var.budget_amount >= 1
    error_message = "The budget amount must be at least 1."
  }
}

variable "budget_start_date" {
  description = "First day of the month when the budget starts, in YYYY-MM-01 format."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-01$", var.budget_start_date))
    error_message = "The budget start date must be the first day of a month, in YYYY-MM-01 format."
  }
}

variable "alert_email" {
  description = "E-mail address that receives the budget alerts and the warning before the daily shutdown."
  type        = string
}

variable "learner_ip" {
  description = "Public IPv4 address allowed to reach the lab VM over SSH, without /32."
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key of the admin user. Never a private key."
  type        = string
}

variable "admin_username" {
  description = "Admin user name on the lab VM."
  type        = string
  default     = "azureuser"
}

variable "vm_size" {
  description = "Size of the lab VM."
  type        = string
  default     = "Standard_D2as_v5"
}

variable "vm_image" {
  description = "Marketplace image of the lab VM, as publisher:offer:sku:version."
  type        = string
  default     = "Canonical:ubuntu-26_04-lts:server:latest"

  validation {
    condition     = length(split(":", var.vm_image)) == 4
    error_message = "The image must have the form publisher:offer:sku:version."
  }
}

variable "os_disk_size_gb" {
  description = "Size of the OS disk in GiB."
  type        = number
  default     = 64

  validation {
    condition     = contains([32, 64, 128], var.os_disk_size_gb)
    error_message = "The OS disk size must be 32, 64 or 128."
  }
}

variable "auto_shutdown_time" {
  description = "Daily shutdown time of the lab VM, in hhmm format."
  type        = string
  default     = "1900"
}

variable "auto_shutdown_timezone" {
  description = "Windows time zone ID for the shutdown time, for example UTC or W. Europe Standard Time."
  type        = string
  default     = "UTC"
}

variable "state_resource_group_name" {
  description = "Resource group of the storage account that holds the Terraform state of the course."
  type        = string
}

variable "state_storage_account_name" {
  description = "Storage account that holds the Terraform state. The lab VM gets access to it for the later chapters."
  type        = string
}
