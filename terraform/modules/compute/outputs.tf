output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
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

output "ssh_bastion" {
  value = "ssh -i ~/.ssh/id_ed25519 ubuntu@${aws_instance.bastion.public_ip}"
}

output "ssh_control_planes" {
  value = [
    for cp in aws_instance.control_plane :
    "ssh -i ~/.ssh/id_ed25519 -J ubuntu@${aws_instance.bastion.public_ip} ubuntu@${cp.private_ip}"
  ]
}

output "ssh_workers" {
  value = [
    for w in aws_instance.worker :
    "ssh -i ~/.ssh/id_ed25519 -J ubuntu@${aws_instance.bastion.public_ip} ubuntu@${w.private_ip}"
  ]
}
