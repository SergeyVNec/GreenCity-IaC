resource "aws_instance" "app" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.security_group_ids
  iam_instance_profile        = var.instance_profile_name
  key_name                    = var.key_name
  associate_public_ip_address = true

  # Prepare the host: Docker, AWS CLI v2, compose plugin, and log in to ECR.
  # SSM agent is preinstalled on Amazon Linux 2023. Running the app containers
  # is done by the deploy step (Jenkins -> SSM), once images are in ECR.
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    dnf update -y
    dnf install -y docker unzip
    systemctl enable --now docker
    usermod -aG docker ec2-user

    # AWS CLI v2 (not bundled on AL2023)
    if ! command -v aws >/dev/null 2>&1; then
      curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
      unzip -q /tmp/awscliv2.zip -d /tmp
      /tmp/aws/install
    fi

    # docker compose plugin
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -sL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

    # Log in to ECR so the instance can pull images
    aws ecr get-login-password --region ${var.region} \
      | docker login --username AWS --password-stdin ${var.ecr_registry}
  EOF

  # Re-run user_data / recreate if the script changes
  user_data_replace_on_change = true

  tags = { Name = "${var.project_name}-app" }
}
