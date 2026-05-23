# ── Network ───────────────────────────────────────────────────────────────────

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_cidrs" {
  value       = module.vpc.private_subnet_cidrs
  description = "All private subnet CIDRs (AZ-a + AZ-b if enabled)"
}

# ── Compute ───────────────────────────────────────────────────────────────────

output "bastion_public_ip" {
  value = module.compute.bastion_public_ip
}

output "control_plane_private_ips" {
  value = module.compute.control_plane_private_ips
}

output "control_plane_private_ip" {
  value       = module.compute.control_plane_private_ips[0]
  description = "First control plane IP (for SSH tunnel and Kubespray)"
}

output "worker_private_ips" {
  value       = module.compute.worker_private_ips
  description = "Stateful worker IPs (Vault, Harbor, cert-manager)"
}

output "apps_worker_private_ips" {
  value       = module.compute.apps_worker_private_ips
  description = "Apps worker IPs (microservices)"
}

output "spot_asg_name" {
  value = module.compute.spot_asg_name
}

output "ssh_bastion" {
  value = module.compute.ssh_bastion
}

# ── IAM ───────────────────────────────────────────────────────────────────────

output "base_instance_profile" {
  value       = module.iam.base_instance_profile_name
  description = "IAM profile for control-plane, apps-worker, spot nodes"
}

output "stateful_instance_profile" {
  value       = module.iam.stateful_instance_profile_name
  description = "IAM profile for stateful worker nodes (Vault, Harbor, cert-manager)"
}

# ── Load balancers ────────────────────────────────────────────────────────────

output "api_nlb_dns" {
  value       = module.nlb.dns_name
  description = "Internal NLB DNS for K8s API server (port 6443)"
}

output "ingress_nlb_dns" {
  value       = module.ingress_nlb.dns_name
  description = "Public NLB DNS for ingress traffic (ports 80/443)"
}

# ── DNS ───────────────────────────────────────────────────────────────────────

output "route53_name_servers" {
  value       = var.domain_name != "" ? module.route53[0].name_servers : []
  description = "Add these NS records to your domain registrar (e.g. Namecheap)"
}

output "route53_zone_id" {
  value       = var.domain_name != "" ? module.route53[0].zone_id : ""
  description = "Route53 hosted zone ID"
}

output "cluster_name" {
  value       = var.cluster_name
  description = "Cluster name (used by deploy.sh scripts)"
}
