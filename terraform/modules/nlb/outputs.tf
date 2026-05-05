output "dns_name" {
  value       = aws_lb.k8s_api.dns_name
  description = "Internal DNS name of the API server NLB"
}

output "arn" {
  value = aws_lb.k8s_api.arn
}
