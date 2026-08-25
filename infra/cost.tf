resource "aws_dynamodb_table" "build_lock" {
  name         = "${var.project_name}-build-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  ttl {
    # GLOBAL leases use lease_expires_at instead: native TTL cannot check EC2
    # liveness. This attribute is only for session-history garbage collection.
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_sns_topic" "cost_alerts" {
  name = "${var.project_name}-cost-alerts"
}

data "aws_iam_policy_document" "cost_alerts" {
  statement {
    sid     = "AllowAWSBudgetsAndCloudWatch"
    actions = ["sns:Publish"]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com", "cloudwatch.amazonaws.com"]
    }

    resources = [aws_sns_topic.cost_alerts.arn]
  }
}

resource "aws_sns_topic_policy" "cost_alerts" {
  arn    = aws_sns_topic.cost_alerts.arn
  policy = data.aws_iam_policy_document.cost_alerts.json
}

resource "aws_sns_topic_subscription" "cost_email" {
  count = var.budget_notification_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.cost_alerts.arn
  protocol  = "email"
  endpoint  = var.budget_notification_email
}

resource "aws_budgets_budget" "project" {
  name         = "${var.project_name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Project$%s", var.project_name)]
  }

  dynamic "notification" {
    for_each = toset([50, 80, 100])
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value
      threshold_type            = "PERCENTAGE"
      notification_type         = notification.value == 100 ? "ACTUAL" : "FORECASTED"
      subscriber_sns_topic_arns = [aws_sns_topic.cost_alerts.arn]
    }
  }

  depends_on = [aws_sns_topic_policy.cost_alerts]
}

resource "aws_cloudwatch_metric_alarm" "cache_size" {
  alarm_name          = "${var.project_name}-cache-size"
  alarm_description   = "Signed Nix cache exceeded the reviewed storage threshold"
  namespace           = "AWS/S3"
  metric_name         = "BucketSizeBytes"
  statistic           = "Average"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.cache_size_alarm_bytes
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.cost_alerts.arn]

  dimensions = {
    BucketName  = aws_s3_bucket.cache.id
    StorageType = "StandardStorage"
  }
}
