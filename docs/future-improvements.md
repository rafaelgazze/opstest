# Future Improvements

This document catalogues planned enhancements that are out of scope for the current implementation but have been considered in the architecture. Each section includes a concrete implementation path.

---

## Monitoring

### CloudWatch Dashboards

Create a dashboard per environment that aggregates the key operational metrics for both the ALB and the active EC2 fleet.

**Recommended widgets**:

| Metric | Source | Statistic |
|--------|--------|-----------|
| `RequestCount` | ALB | Sum (1-min) |
| `TargetResponseTime` (p50, p95, p99) | ALB | p-statistic |
| `HTTPCode_Target_5XX_Count` | ALB | Sum |
| `HTTPCode_Target_2XX_Count` | ALB | Sum |
| `UnHealthyHostCount` | Target group (blue + green) | Maximum |
| `CPUUtilization` | EC2 ASG | Average |
| `NetworkIn` / `NetworkOut` | EC2 ASG | Sum |

The dashboard JSON can be managed as a Terraform resource:

```hcl
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project}-${var.environment}"
  dashboard_body = templatefile("${path.module}/templates/dashboard.json", {
    alb_arn_suffix = aws_lb.main.arn_suffix
    blue_tg_arn    = aws_lb_target_group.blue.arn_suffix
    green_tg_arn   = aws_lb_target_group.green.arn_suffix
    region         = var.region
  })
}
```

### CloudWatch Alarms

**5xx error rate alarm** — fire when the ratio of 5xx responses exceeds 1% of total requests over a 5-minute window:

```hcl
resource "aws_cloudwatch_metric_alarm" "high_5xx_rate" {
  alarm_name          = "${var.project}-${var.environment}-high-5xx-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 1

  metric_query {
    id          = "error_rate"
    expression  = "errors / requests * 100"
    label       = "5xx Error Rate (%)"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"
      dimensions  = { LoadBalancer = aws_lb.main.arn_suffix }
    }
  }

  metric_query {
    id = "requests"
    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"
      dimensions  = { LoadBalancer = aws_lb.main.arn_suffix }
    }
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
```

**Unhealthy host alarm** — fire immediately if any target group has unhealthy hosts:

```hcl
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  for_each = {
    blue  = aws_lb_target_group.blue.arn_suffix
    green = aws_lb_target_group.green.arn_suffix
  }

  alarm_name          = "${var.project}-${var.environment}-unhealthy-${each.key}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = each.value
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}
```

### SNS Notifications

```hcl
resource "aws_sns_topic" "alerts" {
  name = "${var.project}-${var.environment}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
```

---

## Centralised Logging

### CloudWatch Logs Agent on EC2

The Packer template already installs `amazon-cloudwatch-agent`. Add a CloudWatch agent configuration file to the AMI bake:

```hcl
# In packer/app.pkr.hcl
provisioner "file" {
  source      = "cloudwatch-agent-config.json"
  destination = "/tmp/cloudwatch-agent-config.json"
}

provisioner "shell" {
  inline = [
    "sudo cp /tmp/cloudwatch-agent-config.json /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json",
    "sudo systemctl enable amazon-cloudwatch-agent",
    "sudo systemctl start amazon-cloudwatch-agent"
  ]
}
```

**`cloudwatch-agent-config.json`** — forward the systemd journal to CloudWatch:

```json
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/messages",
            "log_group_name": "/suchapp/{env}/system",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  },
  "metrics": {
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["used_percent"], "resources": ["/"] }
    }
  }
}
```

For the application log, configure the Spring Boot app to write to a file (e.g. `/var/log/suchapp/app.log`) and include that path in the agent config.

### Log Groups and Retention

```hcl
resource "aws_cloudwatch_log_group" "app" {
  name              = "/suchapp/${var.environment}/app"
  retention_in_days = var.environment == "prod" ? 90 : 14

  tags = {
    Name        = "${var.project}-${var.environment}-app-logs"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_log_group" "system" {
  name              = "/suchapp/${var.environment}/system"
  retention_in_days = var.environment == "prod" ? 30 : 7
}
```

The EC2 IAM role needs `logs:CreateLogGroup`, `logs:CreateLogStream`, and `logs:PutLogEvents` on the log group ARNs.

### ELK / OpenSearch Option

For environments requiring full-text search over logs, structured querying, or long-term retention beyond 90 days, ship logs from CloudWatch Logs to Amazon OpenSearch Service via a Lambda subscription filter. This is significantly more complex and expensive than CloudWatch Logs alone and is only warranted for high-traffic production workloads.

---

## HTTPS

### ACM Certificate

```hcl
resource "aws_acm_certificate" "main" {
  domain_name       = "suchapp.example.com"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }
  zone_id = aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
```

### HTTPS Listener (port 443)

Replace the HTTP listener in `terraform/alb.tf` with an HTTPS listener and add an HTTP-to-HTTPS redirect:

```hcl
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.main.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
```

Add port 443 to the ALB security group ingress rules.

### Route 53 DNS

```hcl
resource "aws_route53_record" "app" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "suchapp.example.com"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
```

---

## Auto-Scaling

### Target Tracking Policies

Attach scaling policies to the active ASG to maintain target CPU utilisation and request volume. Because the deploy script controls min/max/desired directly, these policies should be applied after traffic is switched and removed before the next deployment (or managed with `lifecycle { ignore_changes }`).

```hcl
resource "aws_autoscaling_policy" "cpu_tracking" {
  name                   = "${var.project}-${var.environment}-cpu-tracking"
  autoscaling_group_name = aws_autoscaling_group.blue.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}

resource "aws_autoscaling_policy" "request_count_tracking" {
  name                   = "${var.project}-${var.environment}-rps-tracking"
  autoscaling_group_name = aws_autoscaling_group.blue.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.blue.arn_suffix}"
    }
    target_value = 1000.0
  }
}
```

### Scheduled Scaling for Dev

Scale the dev environment to zero outside business hours to eliminate EC2 and NAT costs overnight and on weekends:

```hcl
resource "aws_autoscaling_schedule" "dev_scale_down" {
  count                  = var.environment == "dev" ? 1 : 0
  scheduled_action_name  = "scale-down-evenings"
  autoscaling_group_name = aws_autoscaling_group.blue.name
  min_size               = 0
  max_size               = 0
  desired_capacity       = 0
  recurrence             = "0 19 * * MON-FRI"  # 19:00 UTC weekdays
  time_zone              = "UTC"
}

resource "aws_autoscaling_schedule" "dev_scale_up" {
  count                  = var.environment == "dev" ? 1 : 0
  scheduled_action_name  = "scale-up-mornings"
  autoscaling_group_name = aws_autoscaling_group.blue.name
  min_size               = 1
  max_size               = 2
  desired_capacity       = 2
  recurrence             = "0 7 * * MON-FRI"   # 07:00 UTC weekdays
  time_zone              = "UTC"
}
```

---

## CI/CD Enhancements

### Test Stages in Build Pipeline

Add integration and smoke test jobs between the build and bake steps:

```yaml
# .github/workflows/build.yml

  integration-test:
    name: Integration Tests
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: corretto
          java-version: "11"
          cache: maven
      - name: Run integration tests
        run: mvn verify -Pintegration-tests

  smoke-test:
    name: Smoke Test (deployed dev)
    needs: deploy-dev
    runs-on: ubuntu-latest
    steps:
      - name: Health check
        run: |
          curl -f "http://${{ needs.deploy-dev.outputs.alb_dns }}/hello" \
            --retry 5 --retry-delay 5
```

### Environment Promotion Gates

Use GitHub Environments with required reviewers to enforce manual approval before promoting a build to staging or production:

```yaml
  deploy-staging:
    environment:
      name: staging
      # Configure "Required reviewers" in GitHub repo Settings > Environments
    needs: smoke-test
```

### Canary Deployments with Weighted Target Groups

Instead of a hard listener swap, use a weighted forward action to gradually shift traffic:

```hcl
# 90% blue / 10% green
resource "aws_lb_listener_rule" "canary" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type = "forward"
    forward {
      target_group {
        arn    = aws_lb_target_group.blue.arn
        weight = 90
      }
      target_group {
        arn    = aws_lb_target_group.green.arn
        weight = 10
      }
    }
  }

  condition {
    path_pattern { values = ["/*"] }
  }
}
```

The deploy script (or a canary controller) adjusts the weights incrementally (10% → 25% → 50% → 100%) and monitors the 5xx alarm between each step. If the alarm fires, weights are reverted.

---

## Cost Optimisation

### Spot Instances

Replace the on-demand launch template with a mixed instances policy that combines on-demand and Spot:

```hcl
resource "aws_autoscaling_group" "blue" {
  # ... existing config ...

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 1
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.app.id
        version            = "$Latest"
      }

      override {
        instance_type = "t3.micro"
      }
      override {
        instance_type = "t3a.micro"
      }
      override {
        instance_type = "t2.micro"
      }
    }
  }
}
```

This keeps one on-demand instance as the guaranteed baseline and fills remaining capacity from Spot pools. The application must handle Spot interruption notices gracefully (Spring Boot shutters in-flight requests during the 2-minute termination window).

### Reserved Instances / Savings Plans

For production workloads with predictable baseline capacity, purchase 1-year Compute Savings Plans. These apply automatically to EC2 usage regardless of instance family or region. Target coverage: on-demand base capacity only; Spot handles burst.

### Dev Environment Idle Cost

With scheduled scaling (see Auto-Scaling above), the dev stack runs zero EC2 instances outside business hours. The NAT Gateway charges a fixed hourly rate regardless of instance count; to eliminate this entirely, consider switching dev to a VPN-based access model or deploying dev into public subnets (with careful security group controls) to remove the NAT dependency.
