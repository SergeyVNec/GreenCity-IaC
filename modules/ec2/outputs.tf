output "instance_id" {
  description = "App instance id (used as SSM deploy target)"
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "Public IP of the app instance"
  value       = aws_instance.app.public_ip
}

output "public_dns" {
  description = "Public DNS of the app instance"
  value       = aws_instance.app.public_dns
}

output "private_ip" {
  description = "Private IP (for the ALB target / inter-service)"
  value       = aws_instance.app.private_ip
}
