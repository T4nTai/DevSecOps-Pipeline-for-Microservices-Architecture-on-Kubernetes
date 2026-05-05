resource "aws_route53_zone" "this" {
  name = var.domain_name

  tags = merge(var.tags, { Name = var.domain_name })
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

# Wildcard CNAME → NLB DNS name
resource "aws_route53_record" "wildcard" {
  zone_id = aws_route53_zone.this.zone_id
  name    = "*.${var.domain_name}"
  type    = "CNAME"
  ttl     = 60
  records = [var.nlb_dns_name]
}
