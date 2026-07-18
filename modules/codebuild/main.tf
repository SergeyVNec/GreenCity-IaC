data "aws_caller_identity" "current" {}

# CodeBuild assumes this role.
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${var.project_name}-codebuild-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "permissions" {
  # CloudWatch Logs for build output
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }

  # ECR auth token is account-wide (must be "*")
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push/pull only to our greencity/* repos
  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/greencity/*"]
  }

  # Read SonarQube host URL + token (SecureString) for the Quality Gate step
  statement {
    sid       = "SonarParams"
    actions   = ["ssm:GetParameters", "ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/greencity/sonar-*"]
  }
  statement {
    sid       = "SonarTokenDecrypt"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "codebuild" {
  name   = "${var.project_name}-codebuild-policy"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.permissions.json
}

resource "aws_codebuild_project" "build" {
  name          = "${var.project_name}-build"
  description   = "Builds backcore/backuser/frontend images and pushes them to ECR"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 60

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_MEDIUM" # 7 GB — needed for the frontend build
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # required for `docker build`

    environment_variable {
      name  = "AWS_REGION"
      value = var.region
    }
    environment_variable {
      name  = "ECR_REGISTRY"
      value = var.ecr_registry
    }
    environment_variable {
      name  = "REPO_BACKCORE"
      value = var.repo_backcore
    }
    environment_variable {
      name  = "BRANCH_BACKCORE"
      value = var.branch_backcore
    }
    environment_variable {
      name  = "REPO_BACKUSER"
      value = var.repo_backuser
    }
    environment_variable {
      name  = "BRANCH_BACKUSER"
      value = var.branch_backuser
    }
    environment_variable {
      name  = "REPO_FRONTEND"
      value = var.repo_frontend
    }
    environment_variable {
      name  = "BRANCH_FRONTEND"
      value = var.branch_frontend
    }
    environment_variable {
      name  = "FRONTEND_API_URL"
      value = var.frontend_api_url
    }
    # SonarQube (CCI) — pulled from SSM Parameter Store, token is a SecureString.
    # Created here with a "PENDING" placeholder so early Jenkins-triggered builds can
    # always resolve the env (they just skip CCI); setup-cluster.ps1 overwrites the
    # values once SonarQube is up.
    environment_variable {
      name  = "SONAR_HOST_URL"
      type  = "PARAMETER_STORE"
      value = aws_ssm_parameter.sonar_host_url.name
    }
    environment_variable {
      name  = "SONAR_TOKEN"
      type  = "PARAMETER_STORE"
      value = aws_ssm_parameter.sonar_token.name
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = file("${path.module}/buildspec.yml")
  }
}

# Placeholder Quality-Gate params so CodeBuild can always resolve its env, even
# before setup-cluster.ps1 configures SonarQube. setup-cluster overwrites the
# values later, so we ignore drift on them.
resource "aws_ssm_parameter" "sonar_host_url" {
  name  = "/${var.project_name}/sonar-host-url"
  type  = "String"
  value = "PENDING"
  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "sonar_token" {
  name  = "/${var.project_name}/sonar-token"
  type  = "SecureString"
  value = "PENDING"
  lifecycle {
    ignore_changes = [value]
  }
}
