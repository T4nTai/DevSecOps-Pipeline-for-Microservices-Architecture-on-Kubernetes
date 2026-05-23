output "base_instance_profile_name" {
  value       = aws_iam_instance_profile.base.name
  description = "IAM profile for control-plane, apps-worker, and spot ASG nodes"
}

output "stateful_instance_profile_name" {
  value       = aws_iam_instance_profile.stateful.name
  description = "IAM profile for on-demand worker nodes running Vault, Harbor, cert-manager"
}

# Keep for backward compatibility during migration
output "instance_profile_name" {
  value       = aws_iam_instance_profile.base.name
  description = "Deprecated: use base_instance_profile_name or stateful_instance_profile_name"
}

output "base_node_role_arn" {
  value = aws_iam_role.base.arn
}

output "stateful_node_role_arn" {
  value = aws_iam_role.stateful.arn
}
