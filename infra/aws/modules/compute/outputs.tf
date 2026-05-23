output "bastion_public_ip" {
  value = var.create_bastion ? aws_instance.bastion[0].public_ip : null
}

output "control_plane_private_ips" {
  value = aws_instance.control_plane[*].private_ip
}

output "control_plane_ids" {
  value = aws_instance.control_plane[*].id
}

output "secondary_control_plane_private_ips" {
  value = aws_instance.control_plane_secondary[*].private_ip
}

output "secondary_control_plane_ids" {
  value = aws_instance.control_plane_secondary[*].id
}

output "all_control_plane_private_ips" {
  description = "All CP IPs (primary + secondary) — used for NLB and inventory."
  value = concat(
    aws_instance.control_plane[*].private_ip,
    aws_instance.control_plane_secondary[*].private_ip
  )
}

output "all_control_plane_ids" {
  description = "All CP instance IDs — used for K8s API NLB target group."
  value = concat(
    aws_instance.control_plane[*].id,
    aws_instance.control_plane_secondary[*].id
  )
}

output "worker_private_ips" {
  description = "Private IPs of on-demand stateful worker nodes."
  value       = aws_instance.worker[*].private_ip
}

output "worker_ids" {
  description = "Instance IDs of on-demand stateful worker nodes."
  value       = aws_instance.worker[*].id
}

output "apps_worker_private_ips" {
  description = "Private IPs of apps worker nodes (microservices)."
  value       = aws_instance.apps_worker[*].private_ip
}

output "apps_worker_ids" {
  description = "Instance IDs of apps worker nodes."
  value       = aws_instance.apps_worker[*].id
}

output "spot_asg_name" {
  value = var.spot_max > 0 ? aws_autoscaling_group.spot[0].name : null
}

output "ssh_bastion" {
  value = var.create_bastion ? "ssh -i ~/.ssh/id_ed25519 ubuntu@${aws_instance.bastion[0].public_ip}" : null
}

output "ssh_control_planes" {
  value = var.create_bastion ? concat(
    [
      for cp in aws_instance.control_plane :
      "ssh -i ~/.ssh/id_ed25519 -J ubuntu@${aws_instance.bastion[0].public_ip} ubuntu@${cp.private_ip}"
    ],
    [
      for cp in aws_instance.control_plane_secondary :
      "ssh -i ~/.ssh/id_ed25519 -J ubuntu@${aws_instance.bastion[0].public_ip} ubuntu@${cp.private_ip}"
    ]
  ) : []
}
