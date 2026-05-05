variable "project_name" {}
variable "location" {}
variable "resource_group_name" {}

variable "subnet_ids" {
  type = map(string)
}

variable "allowed_ssh_ip" {}

variable "enable_wireguard" {
  type    = bool
  default = false
}
