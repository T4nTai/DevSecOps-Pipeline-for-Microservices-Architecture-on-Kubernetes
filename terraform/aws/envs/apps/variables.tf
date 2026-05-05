variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "cluster_name" {
  type    = string
  default = "devsecops-apps"
}

variable "create_bastion" {
  type        = bool
  default     = false
  description = "Enable for initial provisioning via tools bastion + VPC peering."
}

variable "control_plane_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "control_plane_count" {
  type    = number
  default = 1
}

variable "worker_instance_type" {
  type    = string
  default = "t3.large"
}

variable "worker_count" {
  type        = number
  default     = 1
  description = "On-demand workers for base capacity"
}

variable "spot_min" {
  type    = number
  default = 0
}

variable "spot_max" {
  type        = number
  default     = 2
  description = "Spot workers for microservices"
}

variable "ami_id" {
  type        = string
  default     = ""
  description = "Packer AMI ID. Empty = latest Ubuntu 22.04."
}

variable "public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "allowed_ssh_cidr" {
  type    = string
  default = "0.0.0.0/0"
}

variable "k8s_version" {
  type    = string
  default = "1.30"
}

variable "vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.1.10.0/24"
}

variable "private_subnet_cidr" {
  type    = string
  default = "10.1.20.0/24"
}
