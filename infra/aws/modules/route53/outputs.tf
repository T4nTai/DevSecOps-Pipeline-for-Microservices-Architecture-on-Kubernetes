output "zone_id" {
  value       = aws_route53_zone.this.zone_id
  description = "Route53 hosted zone ID"
}

output "name_servers" {
  value       = aws_route53_zone.this.name_servers
  description = "NS records to set at your registrar (one-time setup)"
}

output "apex_fqdn" {
  value       = aws_route53_record.apex.fqdn
  description = "Apex domain FQDN (e.g. tools.example.com)"
}

output "wildcard_fqdn" {
  value       = aws_route53_record.wildcard.fqdn
  description = "Wildcard FQDN (e.g. *.tools.example.com)"
}
