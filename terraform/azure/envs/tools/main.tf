module "rg" {
  source       = "../../modules/resource-group"
  project_name = var.project_name
  environment  = var.environment
  location     = var.location
}

module "network" {
  source              = "../../modules/network"
  resource_group_name = module.rg.name
  location            = var.location
  vnet_name           = "${var.project_name}-${var.environment}-vnet"
  address_space       = var.vnet_cidr
  subnets             = var.subnets
  dns_zone_name       = "k8s.internal"
}

module "security" {
  source              = "../../modules/security"
  resource_group_name = module.rg.name
  location            = var.location
  project_name        = var.project_name
  subnet_ids          = module.network.subnet_ids
  allowed_ssh_ip      = var.allowed_ssh_ip
  enable_wireguard    = true
}

module "bootstrap" {
  source     = "../../modules/bootstrap"
  master_dns = "master.k8s.internal"
}

module "loadbalancer" {
  source              = "../../modules/loadbalancer"
  project_name        = var.project_name
  location            = var.location
  resource_group_name = module.rg.name
}

module "identity" {
  source              = "../../modules/identity"
  project_name        = var.project_name
  location            = var.location
  resource_group_name = module.rg.name
  depends_on          = [module.rg]
}

module "compute" {
  source              = "../../modules/compute"
  resource_group_name = module.rg.name
  location            = var.location
  project_name        = var.project_name
  environment         = var.environment
  subnet_ids          = module.network.subnet_ids
  ssh_public_key      = var.ssh_public_key
  master_static_ips   = ["10.1.1.10"]
  cloud_init_master   = module.bootstrap.master
  cloud_init_worker   = module.bootstrap.worker
  cloud_init_bastion  = module.bootstrap.bastion
  worker_identity_id  = module.identity.identity_id
  dns_zone_name       = module.network.dns_zone_name
  worker_image_id     = var.worker_image_id
  lb_backend_pool_ids = [module.loadbalancer.backend_pool_id]

  # Tools cluster: 1 on-demand worker (Harbor, Vault), 0-1 spot (Jenkins, SonarQube)
  worker_default      = 1
  worker_min          = 1
  worker_max          = 2
  worker_spot_default = 0
  worker_spot_min     = 0
  worker_spot_max     = 1

  depends_on = [module.security, module.identity, module.network]
}

resource "azurerm_role_assignment" "autoscaler_vmss_contributor" {
  scope                = module.compute.worker_vmss_id
  role_definition_name = "Contributor"
  principal_id         = module.identity.principal_id
}

resource "azurerm_role_assignment" "autoscaler_vmss_spot_contributor" {
  scope                = module.compute.worker_vmss_spot_id
  role_definition_name = "Contributor"
  principal_id         = module.identity.principal_id
}

resource "azurerm_role_assignment" "autoscaler_rg_reader" {
  scope                = module.rg.id
  role_definition_name = "Reader"
  principal_id         = module.identity.principal_id
}

resource "local_file" "inventory" {
  content = templatefile("${path.module}/../../modules/inventory/inventory.tftpl", {
    bastion = module.compute.bastion_public_ip
    masters = module.compute.master_private_ips
    ssh_key = var.ssh_private_key_path
  })
  filename = "${path.module}/inventory.ini"
}

data "azurerm_client_config" "current" {}

module "keyvault" {
  source              = "../../modules/keyvault"
  name                = "${var.project_name}-tools-kv"
  location            = var.location
  resource_group_name = module.rg.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = data.azurerm_client_config.current.object_id
}

# VNet peering to apps cluster (apply after apps cluster is deployed)
module "peering" {
  count  = var.enable_vnet_peering ? 1 : 0
  source = "../../modules/peering"

  tools_vnet_name           = module.network.vnet_name
  tools_vnet_id             = module.network.vnet_id
  tools_resource_group_name = module.rg.name
  apps_vnet_name            = var.apps_vnet_name
  apps_vnet_id              = var.apps_vnet_id
  apps_resource_group_name  = var.apps_resource_group_name
  tools_dns_zone_name       = module.network.dns_zone_name
  apps_dns_zone_name        = var.apps_dns_zone_name
}
