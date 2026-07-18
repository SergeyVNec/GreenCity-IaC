# --- Alerts: SNS topic + email subscription (chain: alarm -> SNS -> email) ---
resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# --- Alarm: app instance CPU too high (resource-usage / scalability signal) ---
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.project_name}-app-cpu-high"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { InstanceId = var.app_instance_id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_description   = "App instance CPU > 80% for 10 min"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# --- Alarm: app instance failing status checks (infra health) ---
resource "aws_cloudwatch_metric_alarm" "status_failed" {
  alarm_name          = "${var.project_name}-app-status-failed"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = var.app_instance_id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_description   = "App instance failed EC2 status checks"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# --- Dashboard: quick health view ---
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-app"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title   = "App CPU %"
          region  = var.region
          view    = "timeSeries"
          metrics = [["AWS/EC2", "CPUUtilization", "InstanceId", var.app_instance_id]]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "App network (bytes)"
          region = var.region
          view   = "timeSeries"
          metrics = [
            ["AWS/EC2", "NetworkIn", "InstanceId", var.app_instance_id],
            ["AWS/EC2", "NetworkOut", "InstanceId", var.app_instance_id]
          ]
        }
      }
    ]
  })
}
