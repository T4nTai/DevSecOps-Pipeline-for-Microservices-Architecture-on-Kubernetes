locals {
  common_tags = {
    Project     = "DevSecOps"
    ManagedBy   = "Terraform"
    Environment = "tools"
    Cluster     = var.cluster_name
  }
}
