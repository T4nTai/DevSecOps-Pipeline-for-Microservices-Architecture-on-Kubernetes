variable "tools_cluster_name" {
  type    = string
  default = "devsecops-tools"
}

variable "apps_cluster_name" {
  type    = string
  default = "devsecops-apps"
}

variable "tools_vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "apps_vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}
