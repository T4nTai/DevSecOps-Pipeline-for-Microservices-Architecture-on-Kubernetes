output "bastion_sg_id" {
  value = aws_security_group.bastion.id
}

output "control_plane_sg_id" {
  value       = aws_security_group.control_plane.id
  description = "Dedicated SG for control plane nodes with self-referencing etcd rules (2379/2380)"
}

output "k8s_nodes_sg_id" {
  value = aws_security_group.k8s_nodes.id
}

output "ingress_nlb_sg_id" {
  value = aws_security_group.ingress_nlb.id
}
