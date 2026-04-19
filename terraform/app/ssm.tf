resource "aws_ssm_parameter" "suchname" {
  name        = "/${var.project}/${var.environment}/suchname"
  description = "Application name parameter for suchapp"
  type        = "SecureString"
  value       = "Daniel"

  tags = {
    Name = "${var.project}-${var.environment}-suchname"
  }

  lifecycle {
    ignore_changes = [value]
  }
}
