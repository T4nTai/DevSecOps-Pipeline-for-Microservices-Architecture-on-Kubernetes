output "vpc_id" {
  value = module.vpc.vpc_id
}

output "bastion_public_ip" {
  value = module.compute.bastion_public_ip
}

output "control_plane_private_ips" {
  value = module.compute.control_plane_private_ips
}

output "control_plane_private_ip" {
  value       = module.compute.control_plane_private_ips[0]
  description = "First control plane IP (for SSH tunnel)"
}

output "worker_private_ips" {
  value = module.compute.worker_private_ips
}

output "api_nlb_dns" {
  value = module.nlb.dns_name
}

output "spot_asg_name" {
  value = module.compute.spot_asg_name
}

output "burst_worker_id" {
  value = module.compute.burst_worker_id
}

output "burst_worker_private_ip" {
  value = module.compute.burst_worker_private_ip
}

output "ssh_bastion" {
  value = module.compute.ssh_bastion
}

output "peering_connection_id" {
  value = var.enable_vpc_peering ? module.peering[0].peering_connection_id : null
}

output "ingress_nlb_dns" {
  value       = module.ingress_nlb.dns_name
  description = "Public DNS name of the ingress NLB"
}

output "route53_name_servers" {
  value       = module.route53.name_servers
  description = "Add these NS records to Namecheap for tools.votantai.me"
}
