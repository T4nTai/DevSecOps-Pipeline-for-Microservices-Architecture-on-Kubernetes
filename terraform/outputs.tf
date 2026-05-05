output "vpc_id" {
  value = module.vpc.vpc_id
}

# ── Kubespray cluster outputs ─────────────────────────────────────────────────

output "bastion_public_ip" {
  value = var.use_eks ? null : module.compute[0].bastion_public_ip
}

output "control_plane_private_ips" {
  value = var.use_eks ? null : module.compute[0].control_plane_private_ips
}

output "control_plane_private_ip" {
  value       = var.use_eks ? null : module.compute[0].control_plane_private_ips[0]
  description = "First control plane IP (for SSH tunnel)"
}

output "worker_private_ips" {
  value = var.use_eks ? null : module.compute[0].worker_private_ips
}

output "api_nlb_dns" {
  value = var.use_eks ? null : module.nlb[0].dns_name
}

output "ssh_bastion" {
  value = var.use_eks ? null : module.compute[0].ssh_bastion
}

output "ssh_control_planes" {
  value = var.use_eks ? null : module.compute[0].ssh_control_planes
}

output "ssh_workers" {
  value = var.use_eks ? null : module.compute[0].ssh_workers
}

# ── EKS cluster outputs ───────────────────────────────────────────────────────

output "eks_cluster_name" {
  value = var.use_eks ? module.eks[0].cluster_name : null
}

output "eks_cluster_endpoint" {
  value = var.use_eks ? module.eks[0].cluster_endpoint : null
}

output "eks_kubeconfig_command" {
  value       = var.use_eks ? module.eks[0].kubeconfig_command : null
  description = "Run this after apply to configure kubectl"
}
