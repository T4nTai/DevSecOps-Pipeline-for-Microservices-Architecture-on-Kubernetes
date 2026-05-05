output "bastion_sg_id" {
  value = aws_security_group.bastion.id
}

output "k8s_nodes_sg_id" {
  value = aws_security_group.k8s_nodes.id
}

output "ingress_nlb_sg_id" {
  value = aws_security_group.ingress_nlb.id
}
