terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  
  backend "s3" {
    bucket         = "devsecops-tfstate-991232066758"
    key            = "tools/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

provider "aws" {
  region = var.aws_region
}


# ── VPC ───────────────────────────────────────────────────────────────────────

module "vpc" {
  source = "../../modules/vpc"

  cluster_name          = var.cluster_name
  vpc_cidr              = var.vpc_cidr
  public_subnet_cidr    = var.public_subnet_cidr
  public_subnet_cidr_b  = var.public_subnet_cidr_b  # enables second public subnet in AZ-b
  private_subnet_cidr   = var.private_subnet_cidr
  private_subnet_cidr_b = var.private_subnet_cidr_b # enables second private subnet in AZ-b
  tags                  = local.common_tags
}

# ── Security Groups ───────────────────────────────────────────────────────────

module "security" {
  source = "../../modules/security"

  cluster_name         = var.cluster_name
  vpc_id               = module.vpc.vpc_id
  allowed_ssh_cidr     = var.allowed_ssh_cidr != "" ? var.allowed_ssh_cidr : "127.0.0.1/32"
  allowed_cidr_blocks  = var.allowed_cidr_blocks
  private_subnet_cidrs = module.vpc.private_subnet_cidrs  # list: [AZ-a, AZ-b?]
  tags                 = local.common_tags
}

# ── IAM roles (split by node type) ───────────────────────────────────────────

module "iam" {
  source = "../../modules/iam"

  cluster_name      = var.cluster_name
  vault_kms_key_arn = var.vault_kms_key_arn
  tags              = local.common_tags
}

# ── EC2 instances ─────────────────────────────────────────────────────────────

module "compute" {
  source = "../../modules/compute"

  cluster_name        = var.cluster_name
  public_subnet_id    = module.vpc.public_subnet_id
  private_subnet_id   = module.vpc.private_subnet_id
  private_subnet_b_id = module.vpc.private_subnet_b_id # AZ-b for secondary CPs (HA etcd)

  bastion_sg_id       = module.security.bastion_sg_id
  k8s_nodes_sg_id     = module.security.k8s_nodes_sg_id
  control_plane_sg_id = module.security.control_plane_sg_id # etcd isolation SG

  # Separate IAM profiles per node role
  base_instance_profile_name     = module.iam.base_instance_profile_name
  stateful_instance_profile_name = module.iam.stateful_instance_profile_name

  public_key_path = var.public_key_path
  ami_id          = var.ami_id

  create_bastion                        = true
  bastion_instance_type                 = var.bastion_instance_type
  control_plane_instance_type           = var.control_plane_instance_type
  control_plane_count                   = var.control_plane_count
  secondary_control_plane_instance_type = var.secondary_control_plane_instance_type
  secondary_control_plane_count         = var.secondary_control_plane_count

  # Stateful workers: Vault, Harbor, cert-manager
  worker_instance_type = var.worker_instance_type
  worker_count         = var.worker_count

  # Apps workers: microservices (separate instance type)
  apps_worker_instance_type = var.apps_worker_instance_type
  apps_worker_count         = var.apps_worker_count

  # Spot workers: Jenkins agents, SonarQube
  spot_min            = var.spot_min
  spot_max            = var.spot_max
  spot_instance_types = var.spot_instance_types # multiple types → lower preemption risk

  tags = local.common_tags
}

# ── K8s API NLB (internal) ────────────────────────────────────────────────────

module "nlb" {
  source = "../../modules/nlb"

  cluster_name       = var.cluster_name
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids # all AZs → multi-AZ API NLB
  control_plane_ids  = module.compute.all_control_plane_ids
  tags               = local.common_tags
}

# ── Ingress NLB (public) ──────────────────────────────────────────────────────
# Targets: stateful workers + apps workers (all nodes running Nginx Ingress).

module "ingress_nlb" {
  source = "../../modules/ingress-nlb"

  cluster_name      = var.cluster_name
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids # all AZs → multi-AZ ingress NLB
  nlb_sg_id         = module.security.ingress_nlb_sg_id
  worker_ids        = concat(module.compute.worker_ids, module.compute.apps_worker_ids)
  nlb_log_bucket    = var.nlb_log_bucket # empty = logging disabled
  tags              = local.common_tags
}

# ── Route53 hosted zone + A records → ingress NLB ────────────────────────────
# Zone and ALIAS records are managed together in this state.
# NOTE: terraform destroy will delete the zone — NS records at the registrar
# will need to be updated if the domain is re-created with a new apply.

module "route53" {
  count  = var.domain_name != "" ? 1 : 0
  source = "../../modules/route53"

  domain_name  = var.domain_name
  nlb_dns_name = module.ingress_nlb.dns_name
  nlb_zone_id  = module.ingress_nlb.zone_id
}
