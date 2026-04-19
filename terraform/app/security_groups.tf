resource "aws_security_group" "alb" {
  name_prefix = "${var.project}-${var.environment}-alb-"
  description = "Security group for the application load balancer"
  vpc_id      = local.vpc_id

  tags = {
    Name = "${var.project}-${var.environment}-alb-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "alb_ingress_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow HTTP traffic from the internet"
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "alb_egress_to_ec2" {
  type                     = "egress"
  from_port                = var.app_port
  to_port                  = var.app_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ec2.id
  description              = "Allow traffic to EC2 instances on app port"
  security_group_id        = aws_security_group.alb.id
}

resource "aws_security_group" "ec2" {
  name_prefix = "${var.project}-${var.environment}-ec2-"
  description = "Security group for EC2 application instances"
  vpc_id      = local.vpc_id

  tags = {
    Name = "${var.project}-${var.environment}-ec2-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "ec2_ingress_from_alb" {
  type                     = "ingress"
  from_port                = var.app_port
  to_port                  = var.app_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  description              = "Allow traffic from ALB on app port"
  security_group_id        = aws_security_group.ec2.id
}

resource "aws_security_group_rule" "ec2_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all outbound traffic for NAT, SSM, and package downloads" #checkov:skip=CKV_AWS_382:EC2 instances need outbound for NAT/SSM/yum
  security_group_id = aws_security_group.ec2.id
}
