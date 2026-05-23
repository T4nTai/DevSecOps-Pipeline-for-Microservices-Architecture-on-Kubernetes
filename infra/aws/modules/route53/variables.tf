variable "domain_name" {
  type        = string
  description = "Domain name for the hosted zone (e.g. tools.votantai.me)"

  validation {
    condition     = length(var.domain_name) > 0
    error_message = "domain_name cannot be empty. Set it in terraform.tfvars (e.g. domain_name = \"tools.example.com\")."
  }

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9\\-\\.]{1,61})[a-z0-9]$", var.domain_name))
    error_message = "domain_name must be a valid DNS name (e.g. tools.example.com)."
  }
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
