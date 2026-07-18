output "server_public_ip" {
  value = aws_instance.server.public_ip
}

output "server_private_ip" {
  value = aws_instance.server.private_ip
}

output "server_instance_id" {
  value = aws_instance.server.id
}

output "agent_instance_ids" {
  value = aws_instance.agent[*].id
}

output "splunk_node_public_ip" {
  value = try(aws_instance.splunk[0].public_ip, null)
}

output "observability_eip" {
  description = "Stable public IP for Splunk/Grafana/Prometheus/SonarQube"
  value       = try(aws_eip.splunk[0].public_ip, null)
}

output "sg_id" {
  description = "k3s security group id"
  value       = aws_security_group.k3s.id
}
