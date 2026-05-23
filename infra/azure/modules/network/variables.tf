variable "vnet_name" {
  default = "acctvnet"
}

variable "resource_group_name" {
  type = string
}

variable "location" {}

variable "address_space" {
  default = "10.0.0.0/16"
}

variable "dns_servers" {
  default = []
}

variable "subnets" {
  type = map(string)
  default = {
    private = "10.0.1.0/24"
    public  = "10.0.2.0/24"
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "dns_zone_name" {
  default = "k8s.internal"
}
