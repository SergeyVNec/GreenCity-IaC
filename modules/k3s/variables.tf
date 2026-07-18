variable "project_name" { type = string }
variable "region" { type = string }
variable "ami_id" { type = string }

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "server_instance_type" {
  # Control-plane needs more RAM than t3.small (2GB) once the cluster has real
  # workload + churn. m7i-flex.large (8GB) is free-tier eligible in this account.
  type    = string
  default = "m7i-flex.large"
}

variable "vpc_id" { type = string }
variable "subnet_id" { type = string }
variable "ecr_registry" { type = string }

variable "db_secret_arn" {
  description = "RDS master secret ARN (server reads it to create the k8s Secret)"
  type        = string
}

variable "agent_count" {
  type    = number
  default = 2
}

variable "splunk_node_enabled" {
  description = "Provision a dedicated node for Splunk (needs ~4GB RAM)"
  type        = bool
  default     = true
}

variable "splunk_instance_type" {
  # m7i-flex.large: 2 vCPU / 8 GB, free-tier eligible in this account (t3.medium is not).
  type    = string
  default = "m7i-flex.large"
}

variable "k3s_token" {
  description = "Shared token that joins agents to the server (lab value; override in tfvars for real use)"
  type        = string
  default     = "greencity-k3s-cluster-token"
}

variable "admin_cidr" {
  description = "CIDR allowed to reach the k8s API (6443) and SSH. Restrict to your IP for real use."
  type        = string
  default     = "0.0.0.0/0"
}
