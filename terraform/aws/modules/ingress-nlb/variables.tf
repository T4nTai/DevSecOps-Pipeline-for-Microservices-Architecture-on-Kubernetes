variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_id" {
  type = string
}

variable "nlb_sg_id" {
  type        = string
  description = "Security group ID for the NLB (created in security module)"
}

variable "worker_ids" {
  type        = list(string)
  description = "Worker EC2 instance IDs to register as NLB targets"
}

variable "tags" {
  type    = map(string)
  default = {}
}
