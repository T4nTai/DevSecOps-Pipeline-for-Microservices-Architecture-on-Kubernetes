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
  description = "Second private subnet CIDR in AZ-b (required for EKS). Leave empty for Kubespray."
}

variable "tags" {
  type    = map(string)
  default = {}
}
