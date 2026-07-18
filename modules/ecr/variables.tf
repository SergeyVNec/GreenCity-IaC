variable "project_name" {
  description = "Project name, used as the ECR namespace"
  type        = string
}

variable "repository_names" {
  description = "Short names of the repositories to create (one per image)"
  type        = list(string)
}

variable "max_image_count" {
  description = "How many recent images to keep per repo (older ones expire)"
  type        = number
  default     = 5
}
