resource "aws_launch_template" "app" {
  name_prefix   = "${var.project}-${var.environment}-"
  image_id      = var.ami_id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.ec2.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
  }

  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh", {
    project     = var.project
    environment = var.environment
    app_port    = var.app_port
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project}-${var.environment}-instance"
    }
  }

  tags = {
    Name = "${var.project}-${var.environment}-lt"
  }
}

resource "aws_autoscaling_group" "blue" {
  name                = "${var.project}-${var.environment}-blue"
  min_size            = var.asg_min
  max_size            = var.asg_max
  desired_capacity    = var.asg_desired
  vpc_zone_identifier = local.private_subnet_ids
  target_group_arns   = [aws_lb_target_group.blue.arn]

  health_check_type         = "ELB"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project}-${var.environment}-blue"
    propagate_at_launch = true
  }

  tag {
    key                 = "Color"
    value               = "blue"
    propagate_at_launch = true
  }

  tag {
    key                 = "Active"
    value               = "true"
    propagate_at_launch = true
  }

  # Deploy script manages these — don't let Terraform revert
  lifecycle {
    ignore_changes = [desired_capacity, min_size, max_size, target_group_arns, launch_template]
  }
}

resource "aws_autoscaling_group" "green" {
  name                = "${var.project}-${var.environment}-green"
  min_size            = 0
  max_size            = var.asg_max
  desired_capacity    = 0
  vpc_zone_identifier = local.private_subnet_ids
  target_group_arns   = [aws_lb_target_group.green.arn]

  health_check_type         = "ELB"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project}-${var.environment}-green"
    propagate_at_launch = true
  }

  tag {
    key                 = "Color"
    value               = "green"
    propagate_at_launch = true
  }

  tag {
    key                 = "Active"
    value               = "false"
    propagate_at_launch = true
  }

  # Deploy script manages these — don't let Terraform revert
  lifecycle {
    ignore_changes = [desired_capacity, min_size, max_size, target_group_arns, launch_template]
  }
}
