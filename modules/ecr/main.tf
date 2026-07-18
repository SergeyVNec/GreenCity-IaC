# One repository per image (backcore / backuser / frontend).
resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name                 = "${var.project_name}/${each.value}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # allow `terraform destroy` even if images exist (lab)

  # Vulnerability scan on every push (closes "Scanning images in CI/CD").
  image_scanning_configuration {
    scan_on_push = true
  }
}

# Keep only the last N images per repo (mentor: retention, saves storage/cost).
resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last ${var.max_image_count} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.max_image_count
      }
      action = { type = "expire" }
    }]
  })
}
