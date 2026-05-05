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

variable "ami_id" {
  type        = string
  default     = ""
  description = "Custom AMI ID (Packer build). Empty = latest Ubuntu 22.04."
}

variable "public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "create_bastion" {
  type        = bool
  default     = true
  description = "Create bastion host. Set false after cluster is provisioned to save cost."
}

variable "bastion_instance_type" {
  type    = string
  default = "t3.micro"
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
  description = "On-demand workers for stateful workloads (Harbor, Vault)"
}

variable "spot_min" {
  type        = number
  default     = 0
  description = "Minimum spot worker count"
}

variable "spot_max" {
  type        = number
  default     = 0
  description = "Maximum spot worker count. 0 = disabled."
}

variable "burst_worker_count" {
  type        = number
  default     = 0
  description = "Burst worker — pre-joined to cluster, stopped when idle. 0=disabled, 1=create."
}

variable "tags" {
  type    = map(string)
  default = {}
}
