resource "aws_cloudwatch_log_group" "runners" {
  name              = "/${var.project_name}/runners"
  retention_in_days = 14
}

data "archive_file" "watchdog" {
  type        = "zip"
  source_file = "${path.module}/lambda/watchdog.py"
  output_path = "${path.module}/.watchdog.zip"
}

resource "aws_iam_role" "watchdog" {
  name = "${var.project_name}-watchdog"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "watchdog" {
  name = "${var.project_name}-watchdog"
  role = aws_iam_role.watchdog.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DeleteFleets",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeFleets",
          "ec2:DescribeInstances",
          "ec2:DescribeLaunchTemplates",
          "ec2:TerminateInstances",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:DescribeParameters"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:DeleteParameter"]
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/runs/*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-watchdog:*"
      },
    ]
  })
}

resource "aws_lambda_function" "watchdog" {
  function_name    = "${var.project_name}-watchdog"
  role             = aws_iam_role.watchdog.arn
  handler          = "watchdog.handler"
  runtime          = "python3.13"
  filename         = data.archive_file.watchdog.output_path
  source_code_hash = data.archive_file.watchdog.output_base64sha256
  timeout          = 120

  environment {
    variables = {
      PROJECT_NAME  = var.project_name
      MAX_AGE_HOURS = tostring(var.watchdog_max_age_hours)
    }
  }
}

resource "aws_cloudwatch_event_rule" "watchdog" {
  name                = "${var.project_name}-watchdog"
  description         = "Remove orphaned ephemeral builder resources"
  schedule_expression = "rate(15 minutes)"
}

resource "aws_cloudwatch_event_target" "watchdog" {
  rule = aws_cloudwatch_event_rule.watchdog.name
  arn  = aws_lambda_function.watchdog.arn
}

resource "aws_lambda_permission" "watchdog" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.watchdog.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.watchdog.arn
}
