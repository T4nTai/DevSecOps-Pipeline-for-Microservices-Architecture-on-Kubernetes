variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the API NLB. Pass all AZs to enable multi-AZ (module.vpc.private_subnet_ids)."
}

variable "control_plane_ids" {
  type        = list(string)
  description = "List of control plane instance IDs to register with NLB"
}

variable "tags" {
  type    = map(string)
  default = {}
}
