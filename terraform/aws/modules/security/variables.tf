variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "allowed_ssh_cidr" {
  type = string
}

variable "allowed_cidr_blocks" {
  type        = list(string)
  description = "CIDRs allowed to access services via NLB (ports 80/443)"
}

variable "private_subnet_cidr" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
