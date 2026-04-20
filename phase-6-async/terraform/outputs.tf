output "order_events_topic_arn" {
  description = "SNS topic ARN — publish OrderCreated events here"
  value       = aws_sns_topic.order_events.arn
}

output "queue_urls" {
  description = "SQS queue URLs for each consumer"
  value = {
    for k in local.queues : k => aws_sqs_queue.order[k].id
  }
}

output "dlq_urls" {
  description = "Dead-letter queue URLs — monitor these for failed messages"
  value = {
    for k in local.queues : k => aws_sqs_queue.dlq[k].id
  }
}
