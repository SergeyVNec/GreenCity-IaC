variable "project_name" {
  description = "Project name for naming"
  type        = string
}

variable "vpc_id" {
  description = "VPC id"
  type        = string
}

variable "subnet_ids" {
  description = "Public subnets for the ALB (>= 2 AZs)"
  type        = list(string)
}

variable "alb_sg_id" {
  description = "Security group for the ALB"
  type        = string
}

variable "app_instance_ids" {
  description = "EC2 instance ids to register as targets"
  type        = list(string)
}

variable "frontend_port" {
  description = "Host port the frontend container is published on"
  type        = number
  default     = 4205
}

variable "backcore_port" {
  description = "backcore port"
  type        = number
  default     = 8080
}

variable "backuser_port" {
  description = "backuser port"
  type        = number
  default     = 8060
}
