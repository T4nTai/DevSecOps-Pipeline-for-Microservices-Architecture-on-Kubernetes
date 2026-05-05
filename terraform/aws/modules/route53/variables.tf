variable "domain_name" {
  type        = string
  description = "Domain name for the hosted zone (e.g. tools.votantai.me)"
}

variable "nlb_dns_name" {
  type        = string
  description = "DNS name of the ingress NLB (used for ALIAS and CNAME records)"
}

variable "nlb_zone_id" {
  type        = string
  description = "AWS-managed hosted zone ID of the NLB (used for Route53 ALIAS records)"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags to apply to all resources"
}
