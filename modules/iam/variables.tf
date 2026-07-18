variable "project_name" {
  description = "Project name for naming"
  type        = string
}

variable "db_secret_arn" {
  description = "ARN of the Secrets Manager secret with the DB password (scopes the read permission)"
  type        = string
}
