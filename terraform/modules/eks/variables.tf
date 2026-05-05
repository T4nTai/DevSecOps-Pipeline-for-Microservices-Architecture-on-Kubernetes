variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "At least 2 private subnet IDs in different AZs"
}

variable "k8s_version" {
  type    = string
  default = "1.29"
}

variable "worker_instance_type" {
  type    = string
  default = "t3.large"
}

variable "worker_count" {
  type    = number
  default = 2
}

variable "allowed_ssh_cidr" {
  type    = string
  default = "0.0.0.0/0"
}

variable "extra_api_cidrs" {
  type        = list(string)
  description = "Extra CIDRs allowed to reach EKS API (e.g. tools cluster NAT GW)"
  default     = []
}

variable "harbor_registry" {
  type        = string
  description = "Harbor registry address (host:port) for insecure registry config"
  default     = "10.0.20.60:30002"
}

variable "tags" {
  type    = map(string)
  default = {}
}
