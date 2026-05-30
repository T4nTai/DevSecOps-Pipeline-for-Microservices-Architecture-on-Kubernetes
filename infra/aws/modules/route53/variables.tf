variable "zone_id" {
  type        = string
  description = "Route53 hosted zone ID — passed in from the DNS state via terraform_remote_state"
}

variable "domain_name" {
  type        = string
  description = "Domain name managed by the zone (e.g. tools.example.com)"

  validation {
    condition     = length(var.domain_name) > 0
    error_message = "domain_name cannot be empty."
  }

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9\\-\\.]{1,61})[a-z0-9]$", var.domain_name))
    error_message = "domain_name must be a valid DNS name (e.g. tools.example.com)."
  }
}

variable "nlb_dns_name" {
  type        = string
  description = "DNS name of the ingress NLB (target for ALIAS records)"
}

variable "nlb_zone_id" {
  type        = string
  description = "AWS-managed hosted zone ID of the NLB (required for Route53 ALIAS)"
}
