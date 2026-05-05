locals {
  common_tags = {
    Project     = "DevSecOps"
    ManagedBy   = "Terraform"
    Environment = "apps"
    Cluster     = var.cluster_name
  }
}
