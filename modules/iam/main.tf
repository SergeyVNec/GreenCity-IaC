# Trust policy: this role can be assumed by EC2.
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${var.project_name}-app-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# Accept SSM commands (deploy without SSH) + SSM Session Manager shell.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Pull images from ECR.
resource "aws_iam_role_policy_attachment" "ecr" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Read ONLY the DB password secret (least privilege).
data "aws_iam_policy_document" "secrets" {
  statement {
    sid       = "ReadDbSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }

  # Let the Docker awslogs driver ship container logs to CloudWatch Logs.
  statement {
    sid = "CloudWatchLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["arn:aws:logs:*:*:log-group:/greencity/*", "arn:aws:logs:*:*:log-group:/greencity/*:*"]
  }
}

resource "aws_iam_role_policy" "secrets" {
  name   = "${var.project_name}-app-secrets-read"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.secrets.json
}

# Instance profile = wrapper that lets an EC2 assume the role.
resource "aws_iam_instance_profile" "app" {
  name = "${var.project_name}-app-profile"
  role = aws_iam_role.app.name
}
