output "vnet_id" {
  value = azurerm_virtual_network.vnet.id
}

output "vnet_name" {
  value = azurerm_virtual_network.vnet.name
}

output "subnet_ids" {
  value = {
    for k, subnet in azurerm_subnet.subnet :
    k => subnet.id
  }
}

output "dns_zone_name" {
  value = azurerm_private_dns_zone.k8s.name
}

output "dns_zone_id" {
  value = azurerm_private_dns_zone.k8s.id
}
