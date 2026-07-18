resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-db-subnets"
  subnet_ids = var.subnet_ids
  tags       = { Name = "${var.project_name}-db-subnets" }
}

resource "aws_db_instance" "this" {
  identifier        = "${var.project_name}-db"
  engine            = "postgres"
  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_type      = "gp3"

  db_name  = var.db_name
  username = var.username

  # AWS generates the master password and stores it in Secrets Manager.
  # No password anywhere in code/state (closes Secret Management).
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = var.vpc_security_group_ids
  publicly_accessible    = false
  multi_az               = false

  # Lab settings — fast create/destroy, no final snapshot.
  skip_final_snapshot = true
  apply_immediately   = true

  tags = { Name = "${var.project_name}-db" }
}
