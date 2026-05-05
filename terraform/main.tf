terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "vpc" {
  source = "./modules/vpc"

  cluster_name          = var.cluster_name
  vpc_cidr              = var.vpc_cidr
  public_subnet_cidr    = var.public_subnet_cidr
  private_subnet_cidr   = var.private_subnet_cidr
  private_subnet_cidr_b = var.private_subnet_cidr_b
  tags                  = local.common_tags
}

module "security" {
  source = "./modules/security"

  cluster_name        = var.cluster_name
  vpc_id              = module.vpc.vpc_id
  allowed_ssh_cidr    = var.allowed_ssh_cidr
  private_subnet_cidr = module.vpc.private_subnet_cidr
  tags                = local.common_tags
}

module "iam" {
  source = "./modules/iam"

  cluster_name      = var.cluster_name
  vault_kms_key_arn = var.vault_kms_key_arn
  tags              = local.common_tags
}

# ── Self-managed Kubespray cluster (use_eks = false) ─────────────────────────

module "compute" {
  count  = var.use_eks ? 0 : 1
  source = "./modules/compute"

  cluster_name                = var.cluster_name
  public_subnet_id            = module.vpc.public_subnet_id
  private_subnet_id           = module.vpc.private_subnet_id
  bastion_sg_id               = module.security.bastion_sg_id
  k8s_nodes_sg_id             = module.security.k8s_nodes_sg_id
  instance_profile_name       = module.iam.instance_profile_name
  public_key_path             = var.public_key_path
  bastion_instance_type       = var.bastion_instance_type
  control_plane_instance_type = var.control_plane_instance_type
  control_plane_count         = var.control_plane_count
  worker_instance_type        = var.worker_instance_type
  worker_count                = var.worker_count
  tags                        = local.common_tags
}

module "nlb" {
  count  = var.use_eks ? 0 : 1
  source = "./modules/nlb"

  cluster_name      = var.cluster_name
  vpc_id            = module.vpc.vpc_id
  private_subnet_id = module.vpc.private_subnet_id
  control_plane_ids = module.compute[0].control_plane_ids
  tags              = local.common_tags
}

# ── EKS managed cluster (use_eks = true) ─────────────────────────────────────

module "eks" {
  count  = var.use_eks ? 1 : 0
  source = "./modules/eks"

  cluster_name         = var.cluster_name
  vpc_id               = module.vpc.vpc_id
  vpc_cidr             = var.vpc_cidr
  private_subnet_ids   = module.vpc.private_subnet_ids
  k8s_version          = var.k8s_version
  worker_instance_type = var.worker_instance_type
  worker_count         = var.worker_count
  allowed_ssh_cidr     = var.allowed_ssh_cidr
  extra_api_cidrs      = var.extra_api_cidrs
  harbor_registry      = var.harbor_registry
  tags                 = local.common_tags
}
