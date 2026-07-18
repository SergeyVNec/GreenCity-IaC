output "repository_urls" {
  description = "Map of short name -> ECR repository URL (used by CI to push/pull)"
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "registry_url" {
  description = "ECR registry host (everything before the first slash of any repo URL)"
  value       = split("/", values(aws_ecr_repository.this)[0].repository_url)[0]
}
