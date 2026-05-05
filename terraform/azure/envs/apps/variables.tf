variable "project_name" {
  type        = string
  description = "Project name (used for naming resources)"
}

variable "environment" {
  type        = string
  description = "Environment (apps/tools)"
  default     = "apps"
}

variable "location" {
  type    = string
  default = "Southeast Asia"
}

variable "vnet_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "subnets" {
  type = map(string)
  default = {
    private = "10.0.1.0/24"
    public  = "10.0.2.0/24"
  }
}

variable "ssh_public_key" {
  type        = string
  description = "Path to SSH public key file for VM access"
}

variable "ssh_private_key_path" {
  type    = string
  default = "/tmp/ssh/id_rsa"
}

variable "allowed_ssh_ip" {
  type        = string
  description = "Your IP allowed to SSH into bastion"
}

variable "worker_image_id" {
  type    = string
  default = ""
}

variable "master_image_id" {
  type    = string
  default = ""
}
