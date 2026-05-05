variable "tools_vnet_name" {
  type = string
}

variable "tools_vnet_id" {
  type = string
}

variable "tools_resource_group_name" {
  type = string
}

variable "apps_vnet_name" {
  type = string
}

variable "apps_vnet_id" {
  type = string
}

variable "apps_resource_group_name" {
  type = string
}

variable "tools_dns_zone_name" {
  type    = string
  default = ""
}

variable "apps_dns_zone_name" {
  type    = string
  default = ""
}
