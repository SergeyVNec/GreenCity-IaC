# --- Security group: cluster-internal (self) + API/SSH from admin + web from internet ---
resource "aws_security_group" "k3s" {
  name_prefix = "${var.project_name}-k3s-"
  description = "k3s cluster"
  vpc_id      = var.vpc_id

  # all traffic between cluster nodes (flannel/kubelet/api/etc.)
  ingress {
    description = "cluster internal"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }
  ingress {
    description = "k8s API"
    from_port   = 6443
    to_port     = 6443
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
  ingress {
    description = "HTTP (Traefik ingress)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS (Traefik ingress)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "NodePort range"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-k3s-sg" }
  lifecycle { create_before_destroy = true }
}

# --- IAM: SSM (manage nodes) + ECR read (pull images) ---
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "k3s" {
  name               = "${var.project_name}-k3s-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.k3s.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ecr" {
  role       = aws_iam_role.k3s.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Read the DB password to seed the k8s Secret
data "aws_iam_policy_document" "secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }
}

resource "aws_iam_role_policy" "secrets" {
  name   = "${var.project_name}-k3s-secrets-read"
  role   = aws_iam_role.k3s.id
  policy = data.aws_iam_policy_document.secrets.json
}

# Let the in-cluster MCP server start CI builds (trigger_build tool, via node role/IMDS)
data "aws_iam_policy_document" "codebuild" {
  statement {
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "codebuild" {
  name   = "${var.project_name}-k3s-codebuild"
  role   = aws_iam_role.k3s.id
  policy = data.aws_iam_policy_document.codebuild.json
}

resource "aws_iam_instance_profile" "k3s" {
  name = "${var.project_name}-k3s-profile"
  role = aws_iam_role.k3s.name
}

# --- Server (control plane) ---
resource "aws_instance" "server" {
  ami                         = var.ami_id
  instance_type               = var.server_instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.k3s.id]
  iam_instance_profile        = aws_iam_instance_profile.k3s.name
  associate_public_ip_address = true

  # hop limit 2 lets pods reach IMDS for the node IAM role (MCP trigger_build)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }

  user_data = templatefile("${path.module}/server_user_data.sh.tftpl", {
    region       = var.region
    ecr_registry = var.ecr_registry
    k3s_token    = var.k3s_token
  })
  user_data_replace_on_change = true

  tags = { Name = "${var.project_name}-k3s-server" }
}

# --- Agents (workers) ---
resource "aws_instance" "agent" {
  count                       = var.agent_count
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.k3s.id]
  iam_instance_profile        = aws_iam_instance_profile.k3s.name
  associate_public_ip_address = true

  # hop limit 2 lets pods reach IMDS for the node IAM role (MCP trigger_build)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }

  user_data = templatefile("${path.module}/agent_user_data.sh.tftpl", {
    region            = var.region
    ecr_registry      = var.ecr_registry
    k3s_token         = var.k3s_token
    server_private_ip = aws_instance.server.private_ip
    node_args         = ""
  })
  user_data_replace_on_change = true

  tags = { Name = "${var.project_name}-k3s-agent-${count.index + 1}" }
}

# --- Dedicated node for Splunk (needs ~4GB RAM, doesn't fit on t3.small) ---
# Labeled splunk=true + tainted so only Splunk (with matching toleration) lands here.
resource "aws_instance" "splunk" {
  count                       = var.splunk_node_enabled ? 1 : 0
  ami                         = var.ami_id
  instance_type               = var.splunk_instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.k3s.id]
  iam_instance_profile        = aws_iam_instance_profile.k3s.name
  associate_public_ip_address = true

  # hop limit 2 lets pods reach IMDS for the node IAM role (MCP trigger_build)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }

  user_data = templatefile("${path.module}/agent_user_data.sh.tftpl", {
    region            = var.region
    ecr_registry      = var.ecr_registry
    k3s_token         = var.k3s_token
    server_private_ip = aws_instance.server.private_ip
    node_args         = "--node-label role=splunk --node-taint dedicated=splunk:NoSchedule"
  })
  user_data_replace_on_change = true

  # Splunk image + data need more than the default 8GB root (caused DiskPressure).
  root_block_device {
    volume_size = 40
    volume_type = "gp3"
  }

  tags = { Name = "${var.project_name}-k3s-splunk" }
}

# Stable public IP for the observability node (Splunk/Grafana/Prometheus/SonarQube UIs
# + reachable by CodeBuild for the Quality Gate). Survives instance recreation.
resource "aws_eip" "splunk" {
  count    = var.splunk_node_enabled ? 1 : 0
  instance = aws_instance.splunk[0].id
  domain   = "vpc"
  tags     = { Name = "${var.project_name}-obs-eip" }
}
