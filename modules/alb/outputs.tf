output "alb_dns_name" {
  description = "Public DNS name of the ALB"
  value       = aws_lb.this.dns_name
}

output "frontend_url" {
  description = "Frontend URL (open this in a browser)"
  value       = "http://${aws_lb.this.dns_name}"
}

output "backcore_url" {
  description = "backcore base URL (for REACT_APP config)"
  value       = "http://${aws_lb.this.dns_name}:${var.backcore_port}"
}

output "backuser_url" {
  description = "backuser base URL (for REACT_APP config)"
  value       = "http://${aws_lb.this.dns_name}:${var.backuser_port}"
}
