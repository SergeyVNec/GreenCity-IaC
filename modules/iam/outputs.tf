output "instance_profile_name" {
  description = "Instance profile to attach to the app EC2"
  value       = aws_iam_instance_profile.app.name
}

output "role_arn" {
  description = "ARN of the app role"
  value       = aws_iam_role.app.arn
}
