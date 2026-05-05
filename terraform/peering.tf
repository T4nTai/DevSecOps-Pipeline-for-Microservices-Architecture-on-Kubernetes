module "peering" {
  count  = var.enable_vpc_peering ? 1 : 0
  source = "./modules/peering"

  tools_cluster_name = "devsecops-tools"
  apps_cluster_name  = "devsecops-apps"
  tools_vpc_cidr     = "10.0.0.0/16"
  apps_vpc_cidr      = "10.1.0.0/16"
}
