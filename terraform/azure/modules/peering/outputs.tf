output "tools_to_apps_peering_id" {
  value = azurerm_virtual_network_peering.tools_to_apps.id
}

output "apps_to_tools_peering_id" {
  value = azurerm_virtual_network_peering.apps_to_tools.id
}
