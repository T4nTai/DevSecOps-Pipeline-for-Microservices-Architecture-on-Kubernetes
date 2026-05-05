resource "azurerm_public_ip" "lb_ip" {
  name                = "${var.project_name}-lb-ip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_lb" "public_lb" {
  name                = "${var.project_name}-lb"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "public"
    public_ip_address_id = azurerm_public_ip.lb_ip.id
  }
}

resource "azurerm_lb_backend_address_pool" "workers" {
  name            = "${var.project_name}-worker-pool"
  loadbalancer_id = azurerm_lb.public_lb.id
}

resource "azurerm_lb_probe" "http" {
  name                = "${var.project_name}-http-probe"
  loadbalancer_id     = azurerm_lb.public_lb.id
  protocol            = "Tcp"
  port                = 30080
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_probe" "https" {
  name                = "${var.project_name}-https-probe"
  loadbalancer_id     = azurerm_lb.public_lb.id
  protocol            = "Tcp"
  port                = 30443
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "http" {
  name                           = "${var.project_name}-http-rule"
  loadbalancer_id                = azurerm_lb.public_lb.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 30080
  frontend_ip_configuration_name = "public"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.workers.id]
  probe_id                       = azurerm_lb_probe.http.id
  idle_timeout_in_minutes        = 4
  disable_outbound_snat          = false
}

resource "azurerm_lb_rule" "https" {
  name                           = "${var.project_name}-https-rule"
  loadbalancer_id                = azurerm_lb.public_lb.id
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 30443
  frontend_ip_configuration_name = "public"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.workers.id]
  probe_id                       = azurerm_lb_probe.https.id
  idle_timeout_in_minutes        = 4
  disable_outbound_snat          = false
}
