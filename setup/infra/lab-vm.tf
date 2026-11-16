# Setup: the lab VM and its network, in the lab resource group.

locals {
  vm_name = "${var.prefix}-lab-vm"
  image   = split(":", var.vm_image)

  # cloud-init installs the tools of the course and clones the kit on the first boot. The file uses
  # __ADMIN_USER__ for the admin user name and __KIT_REPO__ for the clone URL of the kit.
  cloud_init = replace(
    replace(file("${path.module}/cloud-init.yaml"), "__ADMIN_USER__", var.admin_username),
    "__KIT_REPO__", var.kit_repo_url
  )
}

resource "azurerm_network_security_group" "lab" {
  name                = "${local.vm_name}-nsg"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags

  security_rule {
    name                       = "allow-ssh-from-learner"
    description                = "SSH from the learner public IP only. Every other inbound connection hits the default deny rule."
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "${var.learner_ip}/32"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "22"
  }
}

resource "azurerm_virtual_network" "lab" {
  name                = "${var.prefix}-lab-vnet"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.20.0.0/16"]
  tags                = local.tags
}

# untaggable: subnets do not accept tags. The virtual network carries them.
resource "azurerm_subnet" "lab" {
  name                 = "lab"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.20.1.0/24"]
}

# untaggable: this links the subnet to the network security group and is not an Azure resource of its own.
resource "azurerm_subnet_network_security_group_association" "lab" {
  subnet_id                 = azurerm_subnet.lab.id
  network_security_group_id = azurerm_network_security_group.lab.id
}

resource "azurerm_public_ip" "lab" {
  name                = "${local.vm_name}-pip"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  ip_version          = "IPv4"
  tags                = local.tags
}

resource "azurerm_network_interface" "lab" {
  name                = "${local.vm_name}-nic"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.lab.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.lab.id
  }
}

resource "azurerm_linux_virtual_machine" "lab" {
  name                            = local.vm_name
  computer_name                   = local.vm_name
  location                        = azurerm_resource_group.lab.location
  resource_group_name             = azurerm_resource_group.lab.name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  custom_data                     = base64encode(local.cloud_init)
  network_interface_ids           = [azurerm_network_interface.lab.id]
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  tags                            = local.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    name                 = "${local.vm_name}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = local.image[0]
    offer     = local.image[1]
    sku       = local.image[2]
    version   = local.image[3]
  }

  lifecycle {
    # cloud-init runs only on the first boot, and a change to custom_data would replace the VM and your work on it.
    # So a later edit of cloud-init.yaml applies to new lab VMs only.
    ignore_changes = [custom_data]
  }

  # The NSG must protect the subnet before the VM gets its public IP address.
  depends_on = [azurerm_subnet_network_security_group_association.lab]
}

# Azure names this schedule shutdown-computevm-<VM name>, the name the portal looks for.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "lab" {
  virtual_machine_id    = azurerm_linux_virtual_machine.lab.id
  location              = azurerm_resource_group.lab.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone
  tags                  = local.tags

  notification_settings {
    enabled         = true
    time_in_minutes = 30
    email           = var.alert_email
  }
}

# untaggable: role assignments do not accept tags.
# Lets scripts on the lab VM create and delete chapter resources in the lab resource group only.
resource "azurerm_role_assignment" "vm_contributor" {
  scope                = azurerm_resource_group.lab.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_linux_virtual_machine.lab.identity[0].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Lab VM manages chapter resources in the lab resource group."
}

# untaggable: role assignments do not accept tags.
# Lets the lab VM push images to registries in the lab resource group (chapter 1).
resource "azurerm_role_assignment" "vm_acr_push" {
  scope                = azurerm_resource_group.lab.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_linux_virtual_machine.lab.identity[0].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Lab VM pushes images to course registries in the lab resource group."
}

data "azurerm_storage_account" "state" {
  name                = var.state_storage_account_name
  resource_group_name = var.state_resource_group_name
}

# untaggable: role assignments do not accept tags.
# Lets Terraform on the lab VM read and write the state of the later chapters, with the VM's identity and no key.
resource "azurerm_role_assignment" "vm_state" {
  scope                = data.azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_virtual_machine.lab.identity[0].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Lab VM reads and writes the Terraform state of the course."
}
