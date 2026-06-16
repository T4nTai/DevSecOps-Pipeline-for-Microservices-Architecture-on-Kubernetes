output "state_bucket_name" {
  value       = aws_s3_bucket.tfstate.bucket
  description = "S3 bucket name (includes account ID suffix) — paste into backend config."
}

output "lock_table_name" {
  value       = aws_dynamodb_table.tfstate_lock.name
  description = "DynamoDB table name — use as dynamodb_table in backend config."
}

output "aws_region" {
  value       = var.aws_region
  description = "AWS region — use as region in other Terraform backend configs."
}
