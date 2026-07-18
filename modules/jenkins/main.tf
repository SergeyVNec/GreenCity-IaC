# --- Security group: Jenkins UI (8080) + SSH from admin CIDR ---
resource "aws_security_group" "jenkins" {
  name_prefix = "${var.project_name}-jenkins-"
  description = "Jenkins UI + SSH"
  vpc_id      = var.vpc_id

  ingress {
    description = "Jenkins UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-jenkins-sg" }
  lifecycle { create_before_destroy = true }
}

# --- IAM: Jenkins can trigger CodeBuild + SSM deploy, and be managed via SSM ---
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "${var.project_name}-jenkins-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "perms" {
  statement {
    sid       = "CodeBuild"
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
    resources = ["*"]
  }
  statement {
    sid       = "SSMDeploy"
    actions   = ["ssm:SendCommand", "ssm:GetCommandInvocation"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "jenkins" {
  name   = "${var.project_name}-jenkins-policy"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.perms.json
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project_name}-jenkins-profile"
  role = aws_iam_role.jenkins.name
}

# --- Instance ---
resource "aws_instance" "jenkins" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.jenkins.id]
  iam_instance_profile        = aws_iam_instance_profile.jenkins.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region            = var.region
    admin_password    = var.admin_password
    codebuild_project = var.codebuild_project
    deploy_document   = var.deploy_document
    app_instance_id   = var.app_instance_id
    discord_webhook   = var.discord_webhook
    jenkins_repos     = var.jenkins_repos
  })
  user_data_replace_on_change = true

  tags = { Name = "${var.project_name}-jenkins" }
}
