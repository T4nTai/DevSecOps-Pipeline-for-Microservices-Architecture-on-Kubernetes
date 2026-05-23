output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "public_subnet_b_id" {
  value       = length(aws_subnet.public_b) > 0 ? aws_subnet.public_b[0].id : ""
  description = "Public subnet ID in AZ-b (empty string when public_subnet_cidr_b is not set)"
}

output "public_subnet_ids" {
  value = concat(
    [aws_subnet.public.id],
    [for s in aws_subnet.public_b : s.id]
  )
  description = "All public subnet IDs (AZ-a + AZ-b if enabled) — use for multi-AZ NLBs"
}

output "private_subnet_id" {
  value = aws_subnet.private.id
}

output "private_subnet_b_id" {
  value       = length(aws_subnet.private_b) > 0 ? aws_subnet.private_b[0].id : ""
  description = "Private subnet ID in AZ-b (empty string when private_subnet_cidr_b is not set)"
}

output "private_subnet_ids" {
  value = concat(
    [aws_subnet.private.id],
    [for s in aws_subnet.private_b : s.id]
  )
}

output "private_subnet_cidr" {
  value       = aws_subnet.private.cidr_block
  description = "Primary private subnet CIDR (AZ-a)"
}

output "private_subnet_cidrs" {
  value = concat(
    [aws_subnet.private.cidr_block],
    [for s in aws_subnet.private_b : s.cidr_block]
  )
  description = "All private subnet CIDRs (AZ-a + AZ-b if enabled)"
}
