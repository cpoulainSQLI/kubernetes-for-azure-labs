# Chapter 0: values that setup prints after terraform apply.

output "resource_group_name" {
  description = "Name of the lab resource group."
  value       = azurerm_resource_group.lab.name
}

output "vm_name" {
  description = "Name of the lab VM."
  value       = azurerm_linux_virtual_machine.lab.name
}

output "public_ip_address" {
  description = "Public IPv4 address of the lab VM."
  value       = azurerm_public_ip.lab.ip_address
}
