locals {
  common_tags = {
    Project     = "DevSecOps"
    ManagedBy   = "Terraform"
    Environment = "devsecops"
    Cluster     = var.cluster_name
  }
}
