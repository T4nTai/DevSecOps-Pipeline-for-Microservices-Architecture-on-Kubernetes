variable "project_name" {
  type    = string
  default = "devsecops"
}

variable "environment" {
  type    = string
  default = "tools"
}

variable "location" {
  type    = string
  default = "Southeast Asia"
}

variable "vnet_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "subnets" {
  type = map(string)
  default = {
    private = "10.1.1.0/24"
    public  = "10.1.2.0/24"
  }
}

variable "ssh_public_key" {
  type = string
}

variable "ssh_private_key_path" {
  type    = string
  default = "/tmp/ssh/id_rsa"
}

variable "allowed_ssh_ip" {
  type = string
}

variable "worker_image_id" {
  type    = string
  default = ""
}

variable "enable_vnet_peering" {
  type        = bool
  default     = false
  description = "Enable VNet peering to apps cluster. Set true after apps cluster is deployed."
}

variable "apps_vnet_name" {
  type    = string
  default = ""
}

variable "apps_vnet_id" {
  type    = string
  default = ""
}

variable "apps_resource_group_name" {
  type    = string
  default = ""
}

variable "apps_dns_zone_name" {
  type    = string
  default = ""
}
