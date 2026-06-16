# Route53 DNS module
#
# Manages the hosted zone AND A records (apex + wildcard) pointing to the
# ingress NLB. Zone is created and destroyed together with the cluster state.
#
# After first apply, set the NS records at your registrar (one-time step):
#   terraform output -json route53_name_servers

resource "aws_route53_zone" "this" {
  name = var.domain_name
}

# Apex ALIAS A record → ingress NLB
# ALIAS (not CNAME) so Route53 evaluates target health and routes traffic
# away from an unhealthy NLB. Resolves without an extra DNS hop.
resource "aws_route53_record" "apex" {
  zone_id = aws_route53_zone.this.zone_id
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
  zone_id = aws_route53_zone.this.zone_id
  name    = "*.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.nlb_dns_name
    zone_id                = var.nlb_zone_id
    evaluate_target_health = true
  }
}
