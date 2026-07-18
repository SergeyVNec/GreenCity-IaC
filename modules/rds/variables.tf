variable "project_name" {
  description = "Project name for naming/tagging"
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the DB subnet group (>= 2 AZs required by RDS)"
  type        = list(string)
}

variable "vpc_security_group_ids" {
  description = "Security groups for the DB instance (the rds SG)"
  type        = list(string)
}

variable "db_name" {
  description = "Initial database name"
  type        = string
  default     = "greencity"
}

variable "username" {
  description = "Master username"
  type        = string
  default     = "greencity"
}

variable "instance_class" {
  description = "RDS instance class (db.t3.micro is free-tier eligible)"
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Storage in GB"
  type        = number
  default     = 20
}
