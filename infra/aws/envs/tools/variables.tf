# ── Cloud / Region ────────────────────────────────────────────────────────────

variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "cluster_name" {
  type    = string
  default = "devsecops-tools"
}

# ── Network ───────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.10.0/24"
}

variable "private_subnet_cidr" {
  type        = string
  default     = "10.0.20.0/24"
  description = "Primary private subnet CIDR (AZ-a). All K8s nodes live here."
}

variable "private_subnet_cidr_b" {
  type        = string
  default     = ""
  description = "Second private subnet CIDR (AZ-b). Set to enable multi-AZ (e.g. 10.0.21.0/24). Leave empty for single-AZ."
}

variable "public_subnet_cidr_b" {
  type        = string
  default     = ""
  description = "Second public subnet CIDR (AZ-b). Required for multi-AZ ingress/API NLBs (e.g. 10.0.11.0/24). Set alongside private_subnet_cidr_b."
}

# ── Access control ────────────────────────────────────────────────────────────

variable "allowed_ssh_cidr" {
  type        = string
  default     = ""
  description = "Your IP/CIDR for bastion SSH access (e.g. 203.0.113.10/32). Do NOT use 0.0.0.0/0 in production."

  validation {
    condition     = var.allowed_ssh_cidr != "0.0.0.0/0" || var.allowed_ssh_cidr == ""
    error_message = "allowed_ssh_cidr must not be 0.0.0.0/0. Set your specific IP/CIDR (e.g. 203.0.113.10/32)."
  }
}

variable "allowed_cidr_blocks" {
  type        = list(string)
  description = "CIDRs allowed to access services via ingress NLB (ports 80/443)"
  default     = ["0.0.0.0/0"]
}

# ── Compute ───────────────────────────────────────────────────────────────────

variable "ami_id" {
  type        = string
  default     = ""
  description = "Packer AMI ID. Empty = latest Ubuntu 22.04."
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
  default = "t3.medium"
}

variable "control_plane_count" {
  type    = number
  default = 1
}

variable "secondary_control_plane_instance_type" {
  type    = string
  default = "t3.small"
}

variable "secondary_control_plane_count" {
  type        = number
  default     = 0
  description = "Secondary control plane nodes for HA etcd. Total CPs must be odd (add 2 for HA: 1+2=3)."
}

variable "worker_instance_type" {
  type        = string
  default     = "t3.large"
  description = "Instance type for stateful workers (Vault, Harbor, cert-manager)."
}

variable "worker_count" {
  type        = number
  default     = 1
  description = "On-demand stateful worker count."
}

variable "apps_worker_instance_type" {
  type        = string
  default     = ""
  description = "Instance type for apps workers (microservices). Defaults to worker_instance_type if empty."
}

variable "apps_worker_count" {
  type        = number
  default     = 1
  description = "Dedicated worker nodes for microservices."
}

variable "spot_min" {
  type    = number
  default = 0
}

variable "spot_max" {
  type        = number
  default     = 2
  description = "Spot worker max count for Jenkins agents + SonarQube."
}

variable "spot_instance_types" {
  type        = list(string)
  default     = ["t3.large", "t3.xlarge", "t2.large"]
  description = "Instance types for spot workers. Multiple types reduce simultaneous preemption risk."
}

variable "nlb_log_bucket" {
  type        = string
  default     = ""
  description = "S3 bucket for NLB access logs (audit trail). Empty = disabled. Bucket must pre-exist with ELB write policy."
}

# ── Kubernetes ────────────────────────────────────────────────────────────────

variable "k8s_version" {
  type    = string
  default = "1.30"
}

# ── Vault KMS ─────────────────────────────────────────────────────────────────

variable "vault_kms_key_arn" {
  type        = string
  default     = ""
  description = "KMS key ARN for Vault auto-unseal. Empty = no KMS policy on stateful nodes."
}

# ── DNS ───────────────────────────────────────────────────────────────────────

variable "domain_name" {
  type        = string
  default     = ""
  description = "Subdomain for tools cluster services (e.g. tools.example.com). Required when using Route53."
}

