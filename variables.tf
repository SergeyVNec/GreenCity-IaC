variable "region" {
  description = "AWS region — keep everything in ONE region/AZ to avoid cross-zone traffic charges"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name, used for tagging and resource naming"
  type        = string
  default     = "greencity"
}

variable "instance_type" {
  description = "EC2 instance type (t2.micro is free-tier eligible)"
  type        = string
  default     = "t2.micro"
}

variable "ami_id" {
  description = "AMI ID override. Leave empty to auto-select the latest Amazon Linux 2023 AMI for var.region (recommended — portable across accounts/regions)."
  type        = string
  default     = ""
}

variable "availability_zones" {
  description = "AZs used for subnets (2 required for ALB/RDS; keep compute + RDS primary in the first)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "app_instance_type" {
  description = "App EC2 size. 3 containers need RAM: t3.small min, t3.medium comfortable. NOT free-tier."
  type        = string
  default     = "t3.small"
}

variable "ecr_repositories" {
  description = "ECR repositories to create — one per application image"
  type        = list(string)
  default     = ["backcore", "backuser", "frontend"]
}

variable "discord_webhook" {
  description = "Discord webhook for Jenkins deploy notifications (empty = no notifications)"
  type        = string
  default     = ""
}

variable "alarm_email" {
  description = "Email for CloudWatch alarm notifications (empty = no email subscription). Confirm the SNS subscription in your inbox."
  type        = string
  default     = ""
}

variable "frontend_api_url" {
  description = "Public origin the frontend is served from (used to bake REACT_APP_USER_API_URL and configure CORS). Empty = use the ALB DNS name."
  type        = string
  default     = ""
}
