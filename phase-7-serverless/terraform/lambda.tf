data "aws_caller_identity" "current" {}

data "aws_secretsmanager_secret" "db_password" {
  name = "${var.project}/db-password"
}

data "aws_sqs_queue" "order_email" {
  name = "${var.project}-order-email"
}

# ── IAM role shared by all Lambda functions ───────────────────────────────────
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.project}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_sqs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name = "lambda-permissions"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.project}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "arn:aws:s3:::${var.project}-*/*"
      }
    ]
  })
}

# ── CloudWatch log groups (7-day retention to control cost) ──────────────────
resource "aws_cloudwatch_log_group" "daily_report" {
  name              = "/aws/lambda/${var.project}-daily-report"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "send_email" {
  name              = "/aws/lambda/${var.project}-send-email"
  retention_in_days = 7
}

# ── Placeholder ZIP packages ─────────────────────────────────────────────────
# Replace these with real Lambda source directories as you build the functions
data "archive_file" "daily_report_placeholder" {
  type        = "zip"
  output_path = "${path.module}/.build/daily-report.zip"
  source {
    content  = "exports.handler = async () => ({ statusCode: 200, body: 'placeholder' });"
    filename = "index.js"
  }
}

data "archive_file" "send_email_placeholder" {
  type        = "zip"
  output_path = "${path.module}/.build/send-email.zip"
  source {
    content  = "exports.handler = async (event) => { console.log(JSON.stringify(event)); };"
    filename = "index.js"
  }
}

# ── Daily report Lambda ───────────────────────────────────────────────────────
# Free tier: 1M requests/month + 400,000 GB-seconds compute
resource "aws_lambda_function" "daily_report" {
  function_name    = "${var.project}-daily-report"
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.daily_report_placeholder.output_path
  source_code_hash = data.archive_file.daily_report_placeholder.output_base64sha256
  timeout          = 300  # 5 minutes — report generation can be slow
  memory_size      = 256  # MB

  environment {
    variables = {
      DATABASE_URL_SECRET_ARN = data.aws_secretsmanager_secret.db_password.arn
      REPORT_RECIPIENTS       = join(",", var.report_recipients)
      AWS_NODEJS_CONNECTION_REUSE_ENABLED = "1"
    }
  }

  depends_on = [aws_cloudwatch_log_group.daily_report]

  tags = { Name = "${var.project}-daily-report" }
}

# EventBridge Scheduler — trigger daily report at 06:00 UTC
resource "aws_scheduler_schedule" "daily_report" {
  name       = "${var.project}-daily-report"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "cron(0 6 * * ? *)"

  target {
    arn      = aws_lambda_function.daily_report.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

resource "aws_iam_role" "scheduler" {
  name = "${var.project}-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "scheduler.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  name = "invoke-lambda"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.daily_report.arn
    }]
  })
}

# ── Email confirmation Lambda — triggered by SQS ─────────────────────────────
resource "aws_lambda_function" "send_email" {
  function_name    = "${var.project}-send-email"
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.send_email_placeholder.output_path
  source_code_hash = data.archive_file.send_email_placeholder.output_base64sha256
  timeout          = 30
  memory_size      = 128 # MB — smallest allocation

  environment {
    variables = {
      AWS_NODEJS_CONNECTION_REUSE_ENABLED = "1"
    }
  }

  depends_on = [aws_cloudwatch_log_group.send_email]

  tags = { Name = "${var.project}-send-email" }
}

# SQS event source mapping — Lambda polls the email queue automatically
resource "aws_lambda_event_source_mapping" "send_email" {
  event_source_arn = data.aws_sqs_queue.order_email.arn
  function_name    = aws_lambda_function.send_email.arn
  batch_size       = 10
}
