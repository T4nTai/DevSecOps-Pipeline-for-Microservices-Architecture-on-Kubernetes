resource "azurerm_virtual_network_peering" "tools_to_apps" {
  name                         = "${var.tools_vnet_name}-to-${var.apps_vnet_name}"
  resource_group_name          = var.tools_resource_group_name
  virtual_network_name         = var.tools_vnet_name
  remote_virtual_network_id    = var.apps_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "apps_to_tools" {
  name                         = "${var.apps_vnet_name}-to-${var.tools_vnet_name}"
  resource_group_name          = var.apps_resource_group_name
  virtual_network_name         = var.apps_vnet_name
  remote_virtual_network_id    = var.tools_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# Link apps DNS zone to tools VNet so tools nodes can resolve apps k8s.internal hostnames
resource "azurerm_private_dns_zone_virtual_network_link" "apps_dns_to_tools_vnet" {
  count                 = var.apps_dns_zone_name != "" ? 1 : 0
  name                  = "${var.tools_vnet_name}-to-apps-dns"
  resource_group_name   = var.apps_resource_group_name
  private_dns_zone_name = var.apps_dns_zone_name
  virtual_network_id    = var.tools_vnet_id
  registration_enabled  = false
}

# Link tools DNS zone to apps VNet
resource "azurerm_private_dns_zone_virtual_network_link" "tools_dns_to_apps_vnet" {
  count                 = var.tools_dns_zone_name != "" ? 1 : 0
  name                  = "${var.apps_vnet_name}-to-tools-dns"
  resource_group_name   = var.tools_resource_group_name
  private_dns_zone_name = var.tools_dns_zone_name
  virtual_network_id    = var.apps_vnet_id
  registration_enabled  = false
}
