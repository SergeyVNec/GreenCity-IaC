variable "project_name" {
  description = "Project name for tagging/naming"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs for the public subnets. Two are required for ALB and the RDS subnet group; compute + RDS primary will live in the first one to avoid cross-AZ traffic."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}
