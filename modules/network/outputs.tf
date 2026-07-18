output "vpc_id" {
  description = "VPC id"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "List of public subnet ids"
  value       = [for s in aws_subnet.public : s.id]
}

output "public_subnets_by_az" {
  description = "Map of AZ -> public subnet id"
  value       = { for az, s in aws_subnet.public : az => s.id }
}
