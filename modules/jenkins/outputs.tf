output "jenkins_url" {
  description = "Jenkins UI (login admin / var.admin_password)"
  value       = "http://${aws_instance.jenkins.public_ip}:8080"
}

output "instance_id" {
  value = aws_instance.jenkins.id
}
