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
  source = "../../modules/vpc"

  cluster_name        = var.cluster_name
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidr  = var.public_subnet_cidr
  private_subnet_cidr = var.private_subnet_cidr
  tags                = local.common_tags
}

module "security" {
  source = "../../modules/security"

  cluster_name        = var.cluster_name
  vpc_id              = module.vpc.vpc_id
  allowed_ssh_cidr    = var.allowed_ssh_cidr
  private_subnet_cidr = module.vpc.private_subnet_cidr
  tags                = local.common_tags
}

module "iam" {
  source = "../../modules/iam"

  cluster_name = var.cluster_name
  tags         = local.common_tags
}

module "compute" {
  source = "../../modules/compute"

  cluster_name                = var.cluster_name
  public_subnet_id            = module.vpc.public_subnet_id
  private_subnet_id           = module.vpc.private_subnet_id
  bastion_sg_id               = module.security.bastion_sg_id
  k8s_nodes_sg_id             = module.security.k8s_nodes_sg_id
  instance_profile_name       = module.iam.instance_profile_name
  public_key_path             = var.public_key_path
  ami_id                      = var.ami_id
  create_bastion              = var.create_bastion
  control_plane_instance_type = var.control_plane_instance_type
  control_plane_count         = var.control_plane_count
  worker_instance_type        = var.worker_instance_type
  worker_count                = var.worker_count
  spot_min                    = var.spot_min
  spot_max                    = var.spot_max
  tags                        = local.common_tags
}

module "nlb" {
  source = "../../modules/nlb"

  cluster_name      = var.cluster_name
  vpc_id            = module.vpc.vpc_id
  private_subnet_id = module.vpc.private_subnet_id
  control_plane_ids = module.compute.control_plane_ids
  tags              = local.common_tags
}
