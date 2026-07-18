output "vpc_id" {
  description = "VPC id"
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet ids"
  value       = module.network.public_subnet_ids
}

output "ecr_repository_urls" {
  description = "ECR repository URLs (used by CI to push/pull images)"
  value       = module.ecr.repository_urls
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint host"
  value       = module.rds.endpoint
}

output "db_secret_arn" {
  description = "Secrets Manager ARN with the DB master password"
  value       = module.rds.master_user_secret_arn
}

output "app_instance_id" {
  description = "App EC2 instance id (SSM deploy target)"
  value       = module.app.instance_id
}

output "app_public_ip" {
  description = "App EC2 public IP"
  value       = module.app.public_ip
}

output "codebuild_project" {
  description = "CodeBuild project name (start with: aws codebuild start-build --project-name <this>)"
  value       = module.codebuild.project_name
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = module.alb.alb_dns_name
}

output "frontend_url" {
  description = "Open this in a browser"
  value       = module.alb.frontend_url
}

output "backcore_url" {
  description = "backcore base URL"
  value       = module.alb.backcore_url
}

output "backuser_url" {
  description = "backuser base URL"
  value       = module.alb.backuser_url
}

output "deploy_document" {
  description = "SSM deploy document name"
  value       = module.deploy.document_name
}

output "jenkins_url" {
  description = "Jenkins UI (login admin / GreenCityAdmin2026)"
  value       = module.jenkins.jenkins_url
}

output "cloudwatch_dashboard" {
  description = "CloudWatch dashboard URL"
  value       = module.monitoring.dashboard
}

output "k3s_server_ip" {
  description = "k3s control-plane public IP"
  value       = module.k3s.server_public_ip
}

output "k3s_server_instance_id" {
  description = "k3s server instance id (SSM target)"
  value       = module.k3s.server_instance_id
}

output "observability_eip" {
  description = "Stable IP for Splunk/Grafana/SonarQube/MCP/ChatOps UIs"
  value       = module.k3s.observability_eip
}
