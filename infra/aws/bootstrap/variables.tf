variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "project_name" {
  type    = string
  default = "devsecops"
}

variable "lock_table_name" {
  type        = string
  default     = "terraform-state-lock"
  description = "DynamoDB table name for Terraform state locking."
}

variable "state_bucket_name" {
  type        = string
  default     = "devsecops-tfstate"
  description = "S3 bucket name for Terraform remote state. Must be globally unique."
}

