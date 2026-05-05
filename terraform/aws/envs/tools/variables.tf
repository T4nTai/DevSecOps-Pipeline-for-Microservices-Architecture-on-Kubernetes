variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "cluster_name" {
  type    = string
  default = "devsecops-tools"
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
  description = "On-demand workers for Harbor + Vault"
}

variable "spot_min" {
  type    = number
  default = 0
}

variable "spot_max" {
  type        = number
  default     = 2
  description = "Spot workers for Jenkins agents + SonarQube"
}

variable "burst_worker_count" {
  type        = number
  default     = 0
  description = "0 = no burst worker. Set 1 to create, then stop instance after Kubespray join."
}

variable "ami_id" {
  type        = string
  default     = ""
  description = "Packer AMI ID. Empty = latest Ubuntu 22.04."
}

variable "public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "allowed_ssh_cidr" {
  type    = string
  default = "0.0.0.0/0"
}

variable "allowed_cidr_blocks" {
  type        = list(string)
  description = "CIDRs allowed to access services via NLB (ports 80/443)"
  default     = ["0.0.0.0/0"]
}

variable "k8s_version" {
  type    = string
  default = "1.30"
}

variable "vault_kms_key_arn" {
  type    = string
  default = ""
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.10.0/24"
}

variable "private_subnet_cidr" {
  type    = string
  default = "10.0.20.0/24"
}

variable "enable_vpc_peering" {
  type    = bool
  default = false
}

variable "apps_cluster_name" {
  type    = string
  default = "devsecops-apps"
}

variable "apps_vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "domain_name" {
  type        = string
  default     = "tools.votantai.me"
  description = "Subdomain for tools cluster services"
}
