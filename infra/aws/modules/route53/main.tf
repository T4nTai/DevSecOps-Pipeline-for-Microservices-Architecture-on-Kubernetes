# Route53 DNS records module
#
# This module manages ONLY the A records (apex + wildcard) pointing to the
# ingress NLB. The Route53 ZONE itself lives in a separate Terraform state
# (infra/aws/dns/) and is never destroyed during cluster rebuilds.
#
# Inputs:
#   zone_id      — from data.terraform_remote_state.dns.outputs.zone_id
#   nlb_dns_name — from module.ingress_nlb.dns_name
#   nlb_zone_id  — from module.ingress_nlb.zone_id (stable even if NLB is replaced)

# Apex ALIAS A record → ingress NLB
# ALIAS (not CNAME) so Route53 evaluates target health and routes traffic
# away from an unhealthy NLB. Resolves without an extra DNS hop.
resource "aws_route53_record" "apex" {
  zone_id = var.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = var.nlb_dns_name
    zone_id                = var.nlb_zone_id
    evaluate_target_health = true
  }
}

# Wildcard ALIAS A record → ingress NLB
# Covers all subdomains: jenkins.*, argocd.*, grafana.*, etc.
resource "aws_route53_record" "wildcard" {
  zone_id = var.zone_id
  name    = "*.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.nlb_dns_name
    zone_id                = var.nlb_zone_id
    evaluate_target_health = true
  }
}
