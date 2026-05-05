locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ======================
# BASTION HOST â€” Spot VM
# ======================
resource "azurerm_public_ip" "bastion_ip" {
  name                = "${local.name_prefix}-bastion-ip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "bastion_nic" {
  name                = "${local.name_prefix}-bastion-nic"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_ids["public"]
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.bastion_ip.id
  }
}

resource "azurerm_linux_virtual_machine" "bastion" {
  name                = "${local.name_prefix}-bastion"
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = "Standard_B2als_v2"
  admin_username      = var.admin_username

  # Spot VM cho bastion
  priority        = "Spot"
  eviction_policy = "Deallocate"
  max_bid_price   = -1

  network_interface_ids = [azurerm_network_interface.bastion_nic.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  custom_data = var.cloud_init_bastion

  tags = {
    env     = var.environment
    project = var.project_name
    role    = "bastion"
  }
}

# ======================
# MASTER NODES â€” Regular 2 vCPU
# ======================
resource "azurerm_network_interface" "master_nic" {
  count               = var.master_count
  name                = "${local.name_prefix}-master-nic-${count.index}"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_ids["private"]
    private_ip_address_allocation = "Static"
    private_ip_address            = var.master_static_ips[count.index]
  }
}

resource "azurerm_linux_virtual_machine" "master" {
  count               = var.master_count
  name                = "${local.name_prefix}-master-${count.index}"
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = var.master_vm_size
  admin_username      = var.admin_username

  network_interface_ids = [
    azurerm_network_interface.master_nic[count.index].id
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  # dynamic "source_image_reference" {
  #   for_each = var.master_image_id == "" ? [1] : []
  #   content {
  #     publisher = "Canonical"
  #     offer     = "0001-com-ubuntu-server-jammy"
  #     sku       = "22_04-lts"
  #     version   = "latest"
  #   }
  # }
  # source_image_id = var.master_image_id != "" ? var.master_image_id : null

  custom_data = var.cloud_init_master

  tags = {
    env     = var.environment
    project = var.project_name
    role    = "master"
  }
}

# ======================
# DNS Record cho master
# ======================
resource "azurerm_private_dns_a_record" "master" {
  count               = var.master_count
  name                = "master${count.index}"
  zone_name           = var.dns_zone_name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [var.master_static_ips[count.index]]
}

resource "azurerm_private_dns_a_record" "master_primary" {
  name                = "master"
  zone_name           = var.dns_zone_name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [var.master_static_ips[0]]
}

# ======================
# WORKER REGULAR â€” VM Scale Set
# ======================
resource "azurerm_linux_virtual_machine_scale_set" "worker_vmss" {
  name                 = "${local.name_prefix}-worker-vmss"
  computer_name_prefix = "worker"
  location             = var.location
  resource_group_name  = var.resource_group_name

  sku       = var.worker_vm_size
  instances = var.worker_default

  admin_username = var.admin_username

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  dynamic "source_image_reference" {
    for_each = var.worker_image_id == "" ? [1] : []
    content {
      publisher = "Canonical"
      offer     = "0001-com-ubuntu-server-jammy"
      sku       = "22_04-lts"
      version   = "latest"
    }
  }

  source_image_id = var.worker_image_id != "" ? var.worker_image_id : null

  network_interface {
    name    = "worker-nic"
    primary = true

    ip_configuration {
      name                                   = "internal"
      primary                                = true
      subnet_id                              = var.subnet_ids["private"]
      load_balancer_backend_address_pool_ids = var.lb_backend_pool_ids
    }
  }

  dynamic "identity" {
    for_each = var.worker_identity_id != "" ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [var.worker_identity_id]
    }
  }

  upgrade_mode = "Automatic"
  custom_data  = var.cloud_init_worker

  tags = {
    env     = var.environment
    project = var.project_name
    role    = "worker"
  }
}

# ======================
# WORKER SPOT â€” VM Scale Set
# ======================
resource "azurerm_linux_virtual_machine_scale_set" "worker_vmss_spot" {
  name                 = "${local.name_prefix}-worker-vmss-spot"
  computer_name_prefix = "wspot"
  location             = var.location
  resource_group_name  = var.resource_group_name

  sku       = var.worker_vm_size
  instances = var.worker_spot_default

  priority        = "Spot"
  eviction_policy = "Deallocate"
  max_bid_price   = -1

  admin_username = var.admin_username

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  dynamic "source_image_reference" {
    for_each = var.worker_image_id == "" ? [1] : []
    content {
      publisher = "Canonical"
      offer     = "0001-com-ubuntu-server-jammy"
      sku       = "22_04-lts"
      version   = "latest"
    }
  }

  source_image_id = var.worker_image_id != "" ? var.worker_image_id : null

  network_interface {
    name    = "worker-spot-nic"
    primary = true

    ip_configuration {
      name                                   = "internal"
      primary                                = true
      subnet_id                              = var.subnet_ids["private"]
      load_balancer_backend_address_pool_ids = var.lb_backend_pool_ids
    }
  }

  dynamic "identity" {
    for_each = var.worker_identity_id != "" ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [var.worker_identity_id]
    }
  }

  upgrade_mode = "Automatic"
  custom_data  = var.cloud_init_worker

  tags = {
    env     = var.environment
    project = var.project_name
    role    = "worker-spot"
  }
}

# ======================
# AUTOSCALE â€” Regular VMSS
# ======================
resource "azurerm_monitor_autoscale_setting" "worker_autoscale" {
  name                = "${local.name_prefix}-autoscale"
  location            = var.location
  resource_group_name = var.resource_group_name
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.worker_vmss.id

  profile {
    name = "cpu-scale"

    capacity {
      default = var.worker_default
      minimum = var.worker_min
      maximum = var.worker_max
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.worker_vmss.id
        operator           = "GreaterThan"
        threshold          = 70
        time_aggregation   = "Average"
        statistic          = "Average"
        time_grain         = "PT1M"
        time_window        = "PT5M"
      }
      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.worker_vmss.id
        operator           = "LessThan"
        threshold          = 30
        time_aggregation   = "Average"
        statistic          = "Average"
        time_grain         = "PT1M"
        time_window        = "PT5M"
      }
      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }
  }
}

# ======================
# AUTOSCALE â€” Spot VMSS
# ======================
resource "azurerm_monitor_autoscale_setting" "worker_spot_autoscale" {
  name                = "${local.name_prefix}-spot-autoscale"
  location            = var.location
  resource_group_name = var.resource_group_name
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.worker_vmss_spot.id

  profile {
    name = "cpu-scale-spot"

    capacity {
      default = var.worker_spot_default
      minimum = var.worker_spot_min
      maximum = var.worker_spot_max
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.worker_vmss_spot.id
        operator           = "GreaterThan"
        threshold          = 70
        time_aggregation   = "Average"
        statistic          = "Average"
        time_grain         = "PT1M"
        time_window        = "PT5M"
      }
      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.worker_vmss_spot.id
        operator           = "LessThan"
        threshold          = 30
        time_aggregation   = "Average"
        statistic          = "Average"
        time_grain         = "PT1M"
        time_window        = "PT5M"
      }
      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }
  }
}
