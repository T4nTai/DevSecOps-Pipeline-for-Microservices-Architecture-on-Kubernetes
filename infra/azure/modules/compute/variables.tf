variable "subnet_ids" {
  type = map(string)
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "admin_username" {
  default = "azureuser"
}

variable "ssh_public_key" {
  type = string
}

variable "master_count" {
  default = 1
}

variable "master_vm_size" {
  default = "Standard_B2as_v2" # â† Ä‘á»•i lÃªn 2 vCPU
}

variable "master_static_ips" {
  type        = list(string)
  description = "Static private IPs for master nodes."
  default     = ["10.0.1.10"]
}

variable "worker_vm_size" {
  default = "Standard_B2as_v2"
}

variable "worker_default" {
  default = 1
}

variable "worker_min" {
  default = 1
}

variable "worker_max" {
  default = 2 # â† max 2 regular workers
}

variable "worker_spot_default" {
  default = 0
}

variable "worker_spot_min" {
  default = 0
}

variable "worker_spot_max" {
  default = 1 # â† max 1 spot worker
}

variable "cloud_init_bastion" {
  type = string
}

variable "cloud_init_master" {
  type = string
}

variable "cloud_init_worker" {
  type = string
}

variable "worker_identity_id" {
  type    = string
  default = ""
}

variable "dns_zone_name" {
  type        = string
  description = "Private DNS zone name"
}

variable "worker_image_id" {
  type        = string
  description = "Custom Packer image ID for worker nodes."
  default     = ""
}

variable "lb_backend_pool_ids" {
  type        = list(string)
  description = "Load balancer backend pool IDs"
  default     = []
}

variable "master_image_id" {
  type        = string
  description = "Custom Packer image ID for master node. Empty = fallback Ubuntu marketplace."
  default     = ""
}
