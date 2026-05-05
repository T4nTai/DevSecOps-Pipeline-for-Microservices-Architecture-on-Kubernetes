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
  description = "First control plane IP"
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
