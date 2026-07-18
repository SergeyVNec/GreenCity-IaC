output "endpoint" {
  description = "RDS endpoint host (use as DATASOURCE host)"
  value       = aws_db_instance.this.address
}

output "port" {
  description = "RDS port"
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Database name"
  value       = aws_db_instance.this.db_name
}

output "username" {
  description = "Master username"
  value       = aws_db_instance.this.username
}

output "master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the master password"
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}
