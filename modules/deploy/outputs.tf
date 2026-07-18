output "document_name" {
  description = "SSM document name — run: aws ssm send-command --document-name <this> --targets ..."
  value       = aws_ssm_document.deploy.name
}
