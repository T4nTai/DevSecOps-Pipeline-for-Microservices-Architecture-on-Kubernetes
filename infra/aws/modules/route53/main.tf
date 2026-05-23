resource "aws_route53_zone" "this" {
  name = var.domain_name

  tags = merge(var.tags, { Name = var.domain_name })

  lifecycle {
    # CRITICAL: Never destroy this zone. Destroying it assigns NEW nameservers,
    # which breaks TLS issuance until the registrar (e.g. Namecheap) is manually
    # updated — a process that can take hours due to DNS propagation delays.
    #
    # The zone outlives the cluster. On redeploy, `01-terraform.sh` imports the
    # existing zone into state so `terraform apply` reuses it instead of recreating.
    #
    # To intentionally delete: remove this lifecycle block first, then destroy.
    prevent_destroy = true
  }
}

# Apex ALIAS A record → NLB
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

# Wildcard ALIAS A record → NLB
# Using ALIAS (not CNAME) so Route53 can evaluate_target_health and route
# traffic away from an unhealthy NLB. CNAME has no health awareness.
# ALIAS also resolves without an extra DNS hop, and NLB zone_id is stable
# even if the NLB is replaced (unlike raw DNS name which can change).
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
