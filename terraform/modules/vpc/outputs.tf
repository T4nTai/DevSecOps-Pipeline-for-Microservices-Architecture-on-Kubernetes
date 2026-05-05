output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "private_subnet_id" {
  value = aws_subnet.private.id
}

output "private_subnet_ids" {
  value = concat(
    [aws_subnet.private.id],
    [for s in aws_subnet.private_b : s.id]
  )
  description = "All private subnet IDs (1 for Kubespray, 2 for EKS)"
}

output "private_subnet_cidr" {
  value = aws_subnet.private.cidr_block
}
