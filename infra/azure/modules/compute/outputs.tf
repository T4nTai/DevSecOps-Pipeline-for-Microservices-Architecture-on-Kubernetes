output "bastion_public_ip" {
  value = azurerm_public_ip.bastion_ip.ip_address
}

output "master_private_ips" {
  value = azurerm_network_interface.master_nic[*].private_ip_address
}

output "master_dns_name" {
  value = "master.${var.dns_zone_name}"
}

output "worker_vmss_name" {
  value = azurerm_linux_virtual_machine_scale_set.worker_vmss.name
}

output "worker_vmss_id" {
  value = azurerm_linux_virtual_machine_scale_set.worker_vmss.id
}

output "worker_vmss_spot_name" {
  value = azurerm_linux_virtual_machine_scale_set.worker_vmss_spot.name
}

output "worker_vmss_spot_id" {
  value = azurerm_linux_virtual_machine_scale_set.worker_vmss_spot.id
}

output "bastion_host" {
  value = azurerm_public_ip.bastion_ip.ip_address
}
