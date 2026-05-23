output "dns_name" {
  value = aws_lb.k8s_api.dns_name
}

output "arn" {
  value = aws_lb.k8s_api.arn
}
