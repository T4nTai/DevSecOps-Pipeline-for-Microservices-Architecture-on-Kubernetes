output "dns_name" {
  value       = aws_lb.ingress.dns_name
  description = "DNS name of the ingress NLB"
}

output "zone_id" {
  value       = aws_lb.ingress.zone_id
  description = "AWS-managed hosted zone ID of the NLB, used for Route53 ALIAS records"
}
