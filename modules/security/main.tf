# ALB: accepts HTTP from the internet.
resource "aws_security_group" "alb" {
  name_prefix = "${var.project_name}-alb-"
  description = "ALB: allow HTTP from the internet"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.alb_ingress_ports
    content {
      description = "Public port ${ingress.value}"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-alb-sg" }
  lifecycle { create_before_destroy = true }
}

# App instances: app ports reachable ONLY from the ALB; SSH from admin CIDR.
resource "aws_security_group" "app" {
  name_prefix = "${var.project_name}-app-"
  description = "App: app ports from ALB, SSH from admin"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.app_ports
    content {
      description     = "App port ${ingress.value} from ALB"
      from_port       = ingress.value
      to_port         = ingress.value
      protocol        = "tcp"
      security_groups = [aws_security_group.alb.id]
    }
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-app-sg" }
  lifecycle { create_before_destroy = true }
}

# RDS: PostgreSQL reachable ONLY from the app security group.
resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  description = "RDS: PostgreSQL from app SG only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from app"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-rds-sg" }
  lifecycle { create_before_destroy = true }
}
