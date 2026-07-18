variable "project_name" { type = string }
variable "region" { type = string }
variable "ami_id" { type = string }

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "vpc_id" { type = string }
variable "subnet_id" { type = string }

variable "codebuild_project" { type = string }
variable "deploy_document" { type = string }
variable "app_instance_id" { type = string }

variable "jenkins_repos" {
  description = "Repos to poll — one freestyle job each"
  type = list(object({
    name   = string
    url    = string
    branch = string
  }))
}

variable "discord_webhook" {
  type    = string
  default = ""
}

variable "admin_password" {
  description = "Jenkins admin password (stored in state — use a throwaway for the lab)"
  type        = string
  default     = "GreenCityAdmin2026"
}

variable "admin_cidr" {
  description = "CIDR allowed to reach Jenkins UI (8080) and SSH. Restrict to your IP for real use."
  type        = string
  default     = "0.0.0.0/0"
}
