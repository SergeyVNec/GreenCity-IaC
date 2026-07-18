variable "project_name" {
  description = "Project name for naming"
  type        = string
}

variable "region" {
  description = "AWS region (for ECR login)"
  type        = string
}

variable "ecr_registry" {
  description = "ECR registry host (123456789012.dkr.ecr.<region>.amazonaws.com)"
  type        = string
}

variable "frontend_api_url" {
  description = "Base URL the frontend uses for the backend (the ALB origin). Baked into the React build."
  type        = string
  default     = "http://localhost:8060"
}

variable "repo_backcore" {
  type    = string
  default = "https://github.com/GreenCity-UA-4823-4826/GreenCityMVP.git"
}

variable "branch_backcore" {
  type    = string
  default = "dev_java21"
}

variable "repo_backuser" {
  type    = string
  default = "https://github.com/GreenCity-UA-4823-4826/GreenCityUser.git"
}

variable "branch_backuser" {
  type    = string
  default = "dev"
}

variable "repo_frontend" {
  type    = string
  default = "https://github.com/GreenCity-UA-4823-4826/GreenCity-Client.git"
}

variable "branch_frontend" {
  type    = string
  default = "dev-react"
}
