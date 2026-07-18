variable "project_name" {
  description = "Project name for naming/tagging"
  type        = string
}

variable "ami_id" {
  description = "AMI id (Amazon Linux 2023)"
  type        = string
}

variable "instance_type" {
  description = "Instance type. Running 3 containers needs RAM — t3.small/medium, NOT t2.micro."
  type        = string
  default     = "t3.small"
}

variable "subnet_id" {
  description = "Public subnet to place the instance in (first AZ)"
  type        = string
}

variable "security_group_ids" {
  description = "Security groups (the app SG)"
  type        = list(string)
}

variable "instance_profile_name" {
  description = "IAM instance profile (ECR pull + Secrets read + SSM)"
  type        = string
}

variable "ecr_registry" {
  description = "ECR registry host, e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com"
  type        = string
}

variable "region" {
  description = "AWS region (for ECR login)"
  type        = string
}

variable "key_name" {
  description = "Optional EC2 key pair for SSH. Leave null — use SSM Session Manager instead."
  type        = string
  default     = null
}
