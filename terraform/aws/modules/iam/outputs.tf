output "instance_profile_name" {
  value = aws_iam_instance_profile.k8s_node.name
}

output "node_role_arn" {
  value = aws_iam_role.k8s_node.arn
}
