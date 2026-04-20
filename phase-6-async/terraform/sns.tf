# SNS topic — single event bus for all order events
# Cost: 1M publishes/month free, $0.50/million after
resource "aws_sns_topic" "order_events" {
  name = "${var.project}-order-events"

  # Encrypt at rest using the AWS-managed SNS key
  kms_master_key_id = "alias/aws/sns"

  tags = { Name = "${var.project}-order-events" }
}
