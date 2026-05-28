variable "aws_region" {
  type        = string
  default     = "ap-southeast-1"
  description = "AWS region — must match the cluster state region"
}

variable "domain_name" {
  type        = string
  description = "Root domain for the hosted zone (e.g. tools.example.com)"

  validation {
    condition     = length(var.domain_name) > 0
    error_message = "domain_name must not be empty."
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the hosted zone"
}
