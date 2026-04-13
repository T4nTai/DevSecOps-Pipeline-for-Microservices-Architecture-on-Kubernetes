output "bastion_public_ip" {
  description = "Public IP of the bastion host (your SSH entry point)"
  value       = aws_instance.bastion.public_ip
}

output "control_plane_private_ip" {
  description = "Private IP of the Kubernetes control-plane node"
  value       = aws_instance.control_plane.private_ip
}

output "worker_private_ips" {
  description = "Private IPs of the Kubernetes worker nodes"
  value       = aws_instance.worker[*].private_ip
}

output "ssh_bastion" {
  description = "SSH command for the bastion host"
  value       = "ssh -i ~/.ssh/id_ed25519 ${var.admin_username}@${aws_instance.bastion.public_ip}"
}

output "ssh_control_plane" {
  description = "SSH command for the control-plane node (via bastion ProxyJump)"
  value       = "ssh -i ~/.ssh/id_ed25519 -J ${var.admin_username}@${aws_instance.bastion.public_ip} ${var.admin_username}@${aws_instance.control_plane.private_ip}"
}

output "ssh_workers" {
  description = "SSH commands for worker nodes (via bastion ProxyJump)"
  value = [
    for w in aws_instance.worker :
    "ssh -i ~/.ssh/id_ed25519 -J ${var.admin_username}@${aws_instance.bastion.public_ip} ${var.admin_username}@${w.private_ip}"
  ]
}

output "k8s_api_endpoint" {
  description = "Kubernetes API server endpoint (accessible from bastion or VPN)"
  value       = "https://${aws_instance.control_plane.private_ip}:6443"
}

output "vpc_id" {
  description = "AWS VPC ID"
  value       = aws_vpc.k8s.id
}
