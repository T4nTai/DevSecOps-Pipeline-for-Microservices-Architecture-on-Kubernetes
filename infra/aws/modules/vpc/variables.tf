variable "cluster_name" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.10.0/24"
}

variable "private_subnet_cidr" {
  type    = string
  default = "10.0.20.0/24"
}

variable "private_subnet_cidr_b" {
  type        = string
  default     = ""
  description = "Second private subnet CIDR in AZ-b (optional, for multi-AZ HA)."
}

variable "public_subnet_cidr_b" {
  type        = string
  default     = ""
  description = "Second public subnet CIDR in AZ-b (optional). Required for multi-AZ NLBs (ingress + API). Set alongside private_subnet_cidr_b (e.g. 10.0.11.0/24)."
}

variable "tags" {
  type    = map(string)
  default = {}
}
