output "resource_group" {
  value = module.rg.name
}

output "bastion_ip" {
  value = module.compute.bastion_public_ip
}

output "master_private_ips" {
  value = module.compute.master_private_ips
}

output "lb_public_ip" {
  value = module.loadbalancer.public_ip
}

output "worker_vmss_name" {
  value = module.compute.worker_vmss_name
}

output "worker_vmss_spot_name" {
  value = module.compute.worker_vmss_spot_name
}

output "vnet_id" {
  value = module.network.vnet_id
}

output "vnet_name" {
  value = module.network.vnet_name
}

output "dns_zone_name" {
  value = module.network.dns_zone_name
}

output "keyvault_name" {
  value = module.keyvault.vault_name
}

output "cluster_info" {
  value = {
    bastion  = module.compute.bastion_public_ip
    masters  = module.compute.master_private_ips
    lb_ip    = module.loadbalancer.public_ip
    ssh_user = "azureuser"
  }
}
