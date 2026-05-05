variable "cluster_name" {
  type = string
}

variable "public_subnet_id" {
  type = string
}

variable "private_subnet_id" {
  type = string
}

variable "bastion_sg_id" {
  type = string
}

variable "k8s_nodes_sg_id" {
  type = string
}

variable "instance_profile_name" {
  type = string
}

variable "public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "bastion_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "control_plane_instance_type" {
  type    = string
  default = "t3.small"
}

variable "control_plane_count" {
  type    = number
  default = 3
}

variable "worker_instance_type" {
  type    = string
  default = "t3.large"
}

variable "worker_count" {
  type    = number
  default = 3
}

variable "tags" {
  type    = map(string)
  default = {}
}
