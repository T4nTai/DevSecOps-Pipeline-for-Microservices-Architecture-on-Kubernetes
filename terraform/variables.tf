variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "ap-southeast-1"
}

variable "cluster_name" {
  description = "Name prefix for all Kubernetes cluster resources"
  type        = string
  default     = "devsecops-k8s"
}

variable "bastion_instance_type" {
  description = "EC2 instance type for the bastion host"
  type        = string
  default     = "t3.micro"
}

variable "control_plane_instance_type" {
  description = "EC2 instance type for control-plane nodes"
  type        = string
  default     = "t3.medium"
}

variable "control_plane_count" {
  description = "Number of control plane nodes (use 3 for HA)"
  type        = number
  default     = 3
}

variable "worker_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.large"
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 3
}

variable "admin_username" {
  description = "Admin username for SSH access to instances"
  type        = string
  default     = "ubuntu"
}

variable "public_key_path" {
  description = "Path to your SSH public key file"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH into nodes and reach the Kubernetes API"
  type        = string
  default     = "0.0.0.0/0"
}

variable "k8s_version" {
  description = "Kubernetes minor version to install (e.g. 1.29)"
  type        = string
  default     = "1.29"
}

variable "vault_kms_key_arn" {
  description = "ARN of the KMS key used for Vault auto-unseal"
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.10.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet (AZ-a)"
  type        = string
  default     = "10.0.20.0/24"
}

variable "private_subnet_cidr_b" {
  description = "Second private subnet CIDR (AZ-b) — required for EKS HA"
  type        = string
  default     = ""
}

variable "use_eks" {
  description = "Use EKS managed cluster instead of self-managed Kubespray"
  type        = bool
  default     = false
}

variable "enable_vpc_peering" {
  description = "Create VPC peering between tools and apps clusters"
  type        = bool
  default     = false
}

variable "extra_api_cidrs" {
  description = "Extra CIDRs allowed to reach EKS API (tools cluster NAT GW for ArgoCD)"
  type        = list(string)
  default     = []
}

variable "harbor_registry" {
  description = "Harbor registry address for EKS insecure registry config"
  type        = string
  default     = "10.0.20.60:30002"
}
