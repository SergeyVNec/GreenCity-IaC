locals {
  # service -> { tg_port (where the container listens on the instance),
  #              listener_port (public port on the ALB) }
  services = {
    frontend = { tg_port = var.frontend_port, listener_port = 80 }
    backcore = { tg_port = var.backcore_port, listener_port = var.backcore_port }
    backuser = { tg_port = var.backuser_port, listener_port = var.backuser_port }
  }

  # flatten service x instance -> attachments.
  # Key by the instance INDEX (static), not its id (known only after apply) — an
  # id in the key breaks for_each on a fresh apply or when the instance is replaced.
  attachments = merge([
    for svc, cfg in local.services : {
      for idx, iid in var.app_instance_ids : "${svc}-${idx}" => {
        svc  = svc
        iid  = iid
        port = cfg.tg_port
      }
    }
  ]...)
}

resource "aws_lb" "this" {
  name               = "${var.project_name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [var.alb_sg_id]
  subnets            = var.subnet_ids

  tags = { Name = "${var.project_name}-alb" }
}

resource "aws_lb_target_group" "this" {
  for_each = local.services

  name     = "${var.project_name}-${each.key}"
  port     = each.value.tg_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/"
    matcher             = "200-499" # lenient: target is "up" if it answers at all
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.project_name}-${each.key}-tg" }
}

resource "aws_lb_listener" "this" {
  for_each = local.services

  load_balancer_arn = aws_lb.this.arn
  port              = each.value.listener_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }
}

resource "aws_lb_target_group_attachment" "this" {
  for_each = local.attachments

  target_group_arn = aws_lb_target_group.this[each.value.svc].arn
  target_id        = each.value.iid
  port             = each.value.port
}
