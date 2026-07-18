variable "project_name" {
  description = "Project name for naming/tagging"
  type        = string
}

variable "vpc_id" {
  description = "VPC to create the security groups in"
  type        = string
}

variable "app_ports" {
  description = "Container ports the app exposes (backcore/backuser/frontend)"
  type        = list(number)
  default     = [8080, 8060, 4205]
}

variable "alb_ingress_ports" {
  description = "Public ports the ALB accepts (80 frontend, 8080 backcore, 8060 backuser)"
  type        = list(number)
  default     = [80, 8080, 8060]
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH to app instances. RESTRICT to your IP for real use (e.g. 1.2.3.4/32)."
  type        = string
  default     = "0.0.0.0/0"
}
