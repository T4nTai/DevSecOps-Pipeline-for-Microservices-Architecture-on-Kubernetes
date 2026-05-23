output "zone_id" {
  value       = aws_route53_zone.this.zone_id
  description = "Route53 hosted zone ID for tools.votantai.me"
}

output "name_servers" {
  value       = aws_route53_zone.this.name_servers
  description = "NS records to configure in Namecheap (or your registrar) for tools.votantai.me"
}

output "zone_name" {
  value       = aws_route53_zone.this.name
  description = "The domain name managed by this hosted zone"
}
