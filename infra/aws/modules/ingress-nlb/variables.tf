variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnet IDs for the ingress NLB. Pass all AZs to enable multi-AZ (module.vpc.public_subnet_ids)."
}

variable "nlb_log_bucket" {
  type        = string
  default     = ""
  description = "S3 bucket name for NLB access logs. Empty = logging disabled. The bucket must have the ELB service account write policy attached."
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
