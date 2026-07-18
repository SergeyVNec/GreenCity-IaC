output "alb_sg_id" {
  description = "ALB security group id"
  value       = aws_security_group.alb.id
}

output "app_sg_id" {
  description = "App instances security group id"
  value       = aws_security_group.app.id
}

output "rds_sg_id" {
  description = "RDS security group id"
  value       = aws_security_group.rds.id
}
