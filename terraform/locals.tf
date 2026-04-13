locals {
  common_tags = {
    Project     = "DevSecOps-K8s"
    ManagedBy   = "Terraform"
    Environment = "dev"
    Cluster     = var.cluster_name
  }
}
