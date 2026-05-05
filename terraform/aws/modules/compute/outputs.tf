output "bastion_public_ip" {
  value = var.create_bastion ? aws_instance.bastion[0].public_ip : null
}

output "control_plane_private_ips" {
  value = aws_instance.control_plane[*].private_ip
}

output "control_plane_ids" {
  value = aws_instance.control_plane[*].id
}

output "worker_private_ips" {
  value = aws_instance.worker[*].private_ip
}

output "worker_ids" {
  value       = aws_instance.worker[*].id
  description = "Instance IDs of on-demand worker nodes (used for NLB target group attachments)"
}

output "spot_asg_name" {
  value = var.spot_max > 0 ? aws_autoscaling_group.spot[0].name : null
}

output "burst_worker_id" {
  value = var.burst_worker_count > 0 ? aws_instance.burst_worker[0].id : ""
}

output "burst_worker_private_ip" {
  value = var.burst_worker_count > 0 ? aws_instance.burst_worker[0].private_ip : ""
}

output "ssh_bastion" {
  value = var.create_bastion ? "ssh -i ~/.ssh/id_ed25519 ubuntu@${aws_instance.bastion[0].public_ip}" : null
}

output "ssh_control_planes" {
  value = var.create_bastion ? [
    for cp in aws_instance.control_plane :
    "ssh -i ~/.ssh/id_ed25519 -J ubuntu@${aws_instance.bastion[0].public_ip} ubuntu@${cp.private_ip}"
  ] : []
}
