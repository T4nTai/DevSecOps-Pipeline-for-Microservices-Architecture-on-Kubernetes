variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_id" {
  type = string
}

variable "control_plane_ids" {
  type        = list(string)
  description = "List of control plane instance IDs to register with NLB"
}

variable "tags" {
  type    = map(string)
  default = {}
}
