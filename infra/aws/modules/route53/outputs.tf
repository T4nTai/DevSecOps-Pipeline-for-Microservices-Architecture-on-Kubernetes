output "apex_fqdn" {
  value       = aws_route53_record.apex.fqdn
  description = "Apex domain FQDN (e.g. tools.example.com)"
}

output "wildcard_fqdn" {
  value       = aws_route53_record.wildcard.fqdn
  description = "Wildcard FQDN (e.g. *.tools.example.com)"
}
