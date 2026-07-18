variable "project_name" { type = string }
variable "region" { type = string }

variable "app_instance_id" {
  description = "App EC2 to watch"
  type        = string
}

variable "alarm_email" {
  description = "Email that receives CloudWatch alarms (confirm the SNS subscription in your inbox)"
  type        = string
}
