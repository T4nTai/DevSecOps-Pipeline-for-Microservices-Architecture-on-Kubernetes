variable "cluster_name" {
  type = string
}

variable "public_subnet_id" {
  type = string
}

variable "private_subnet_id" {
  type        = string
  description = "Primary private subnet ID (AZ-a). Used for primary control plane and all workers."
}

variable "private_subnet_b_id" {
  type        = string
  default     = ""
  description = "Secondary private subnet ID (AZ-b). When set, secondary control planes are placed here for HA etcd quorum across AZs."
}

variable "control_plane_sg_id" {
  type        = string
  default     = ""
  description = "Dedicated security group for control plane nodes (etcd ports). Applied in addition to k8s_nodes_sg_id."
}

variable "bastion_sg_id" {
  type = string
}

variable "k8s_nodes_sg_id" {
  type = string
}

# ── IAM profiles (split by node role) ────────────────────────────────────────

variable "base_instance_profile_name" {
  type        = string
  description = "IAM profile for control-plane, apps-worker, and spot ASG nodes (EBS CSI + autoscaler)"
}

variable "stateful_instance_profile_name" {
  type        = string
  description = "IAM profile for on-demand worker nodes running Vault, Harbor, cert-manager"
}

# ── AMI ───────────────────────────────────────────────────────────────────────

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

# ── Instance types ─────────────────────────────────────────────────────────────

variable "bastion_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "control_plane_instance_type" {
  type        = string
  default     = "t3.medium"
  description = "Instance type for the primary control plane node."
}

variable "control_plane_count" {
  type    = number
  default = 1
}

variable "secondary_control_plane_instance_type" {
  type        = string
  default     = "t3.small"
  description = "Instance type for secondary control plane nodes (etcd members)."
}

variable "secondary_control_plane_count" {
  type        = number
  default     = 0
  description = "Number of secondary control plane nodes. Total CPs must be odd (1, 3, 5)."
}

variable "worker_instance_type" {
  type        = string
  default     = "t3.large"
  description = "Instance type for on-demand stateful worker nodes (Vault, Harbor, cert-manager)."
}

variable "worker_count" {
  type        = number
  default     = 1
  description = "On-demand workers for stateful workloads (Vault, Harbor)"
}

variable "apps_worker_instance_type" {
  type        = string
  default     = ""
  description = "Instance type for apps worker nodes (microservices). Defaults to worker_instance_type if empty."
}

variable "apps_worker_count" {
  type        = number
  default     = 0
  description = "Dedicated worker nodes for apps namespace workloads (microservices)."
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

variable "spot_instance_types" {
  type        = list(string)
  default     = ["t3.large", "t3.xlarge", "t2.large"]
  description = "Instance types for spot workers. Multiple types reduce simultaneous preemption risk. price-capacity-optimized strategy picks the best available."
}

variable "tags" {
  type    = map(string)
  default = {}
}
