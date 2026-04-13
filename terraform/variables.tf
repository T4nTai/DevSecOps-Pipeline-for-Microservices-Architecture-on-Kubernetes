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
  default     = "t3.micro" # 2 vCPU, 1 GB RAM
}

variable "control_plane_instance_type" {
  description = "EC2 instance type for the control-plane node"
  type        = string
  default     = "t3.small" # 2 vCPU, 2 GB RAM
}

variable "worker_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.large" # 2 vCPU, 8 GB RAM
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
