resource "aws_lb" "main" {
  name               = "${var.project}-${var.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.public_subnet_ids

  drop_invalid_header_fields = true

  tags = {
    Name = "${var.project}-${var.environment}-alb"
  }
}

resource "aws_lb_target_group" "blue" {
  name     = "${var.project}-${var.environment}-blue"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = local.vpc_id

  health_check {
    path                = "/hello"
    protocol            = "HTTP"
    port                = tostring(var.app_port)
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }

  tags = {
    Name  = "${var.project}-${var.environment}-blue-tg"
    Color = "blue"
  }
}

resource "aws_lb_target_group" "green" {
  name     = "${var.project}-${var.environment}-green"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = local.vpc_id

  health_check {
    path                = "/hello"
    protocol            = "HTTP"
    port                = tostring(var.app_port)
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }

  tags = {
    Name  = "${var.project}-${var.environment}-green-tg"
    Color = "green"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  # Deploy script swaps this — don't let Terraform revert it
  lifecycle {
    ignore_changes = [default_action]
  }

  tags = {
    Name = "${var.project}-${var.environment}-http-listener"
  }
}
