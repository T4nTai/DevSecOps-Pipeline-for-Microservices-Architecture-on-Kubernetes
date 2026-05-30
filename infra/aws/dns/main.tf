terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state: uncomment and fill in when ready (see backend.tf.example).
  # This state must be initialized BEFORE infra/aws/envs/tools/ because
  # the cluster state reads zone_id via terraform_remote_state.
  #
  # backend "s3" {}
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = var.tags }
}

# ── Route53 hosted zone ───────────────────────────────────────────────────────
# This zone lives in its OWN Terraform state, completely isolated from the
# cluster state in infra/aws/envs/tools/.
#
# WHY: Destroying and re-creating the zone assigns NEW nameservers (NS records).
# Updating NS at the registrar (Namecheap) takes up to 48 h. By keeping the
# zone in a separate state it is never touched during cluster rebuild cycles.
#
# Lifecycle:
#   - First deploy : terraform -chdir=infra/aws/dns apply
#   - Cluster rebuilds: skip this directory entirely — zone stays untouched
#   - Intentional deletion: remove prevent_destroy below, then destroy
resource "aws_route53_zone" "this" {
  name = var.domain_name
}

# ── Outputs consumed by the cluster state ─────────────────────────────────────
# infra/aws/envs/tools reads these via:
#   data "terraform_remote_state" "dns" { ... }
output "zone_id" {
  value       = aws_route53_zone.this.zone_id
  description = "Route53 hosted zone ID — consumed by cluster state for A records"
}

output "name_servers" {
  value       = aws_route53_zone.this.name_servers
  description = "NS records to set at your registrar (one-time setup)"
}

output "domain_name" {
  value       = var.domain_name
  description = "Domain this zone manages"
}
