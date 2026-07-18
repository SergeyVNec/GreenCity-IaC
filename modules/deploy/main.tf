# SSM Command document: pulls images from ECR and (re)starts the containers.
# Run it with:  aws ssm send-command --document-name <name> --targets ...
# This is the deploy hook the CI (Jenkins) will call on every release.
resource "aws_ssm_document" "deploy" {
  name          = "${var.project_name}-deploy"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Pull images from ECR and (re)start GreenCity containers"
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "deploy"
      inputs = {
        runCommand = split("\n", templatefile("${path.module}/deploy.sh.tftpl", {
          region        = var.region
          ecr_registry  = var.ecr_registry
          db_host       = var.db_host
          db_name       = var.db_name
          db_user       = var.db_user
          db_secret_arn = var.db_secret_arn
        }))
      }
    }]
  })
}
