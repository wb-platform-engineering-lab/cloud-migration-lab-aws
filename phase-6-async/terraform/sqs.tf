# SQS queues — one per downstream consumer of order events
# Cost: 1M requests/month free, $0.40/million after

locals {
  queues = ["email", "inventory", "warehouse"]
}

# Dead-letter queues — catch messages that fail processing after max_receive_count attempts
resource "aws_sqs_queue" "dlq" {
  for_each = toset(local.queues)

  name                       = "${var.project}-order-${each.key}-dlq"
  message_retention_seconds  = 1209600 # 14 days — maximum retention
  kms_master_key_id          = "alias/aws/sqs"

  tags = { Name = "${var.project}-order-${each.key}-dlq" }
}

# Main queues — subscribe to the SNS topic
resource "aws_sqs_queue" "order" {
  for_each = toset(local.queues)

  name                       = "${var.project}-order-${each.key}"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 86400 # 1 day
  kms_master_key_id          = "alias/aws/sqs"

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 3
  })

  tags = { Name = "${var.project}-order-${each.key}" }
}

# Queue policies — allow SNS to send messages to each queue
resource "aws_sqs_queue_policy" "order" {
  for_each  = toset(local.queues)
  queue_url = aws_sqs_queue.order[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.order[each.key].arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_sns_topic.order_events.arn
        }
      }
    }]
  })
}

# SNS subscriptions — fan out from the topic to each queue
resource "aws_sns_topic_subscription" "order" {
  for_each = toset(local.queues)

  topic_arn            = aws_sns_topic.order_events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.order[each.key].arn
  raw_message_delivery = true
}
