resource "aws_securityhub_account" "main" {}

# AWS Foundational Security Best Practices
resource "aws_securityhub_standards_subscription" "fsbp" {
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}

# CIS AWS Foundations Benchmark
resource "aws_securityhub_standards_subscription" "cis" {
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/cis-aws-foundations-benchmark/v/1.2.0"
  depends_on    = [aws_securityhub_account.main]
}

# Pipe GuardDuty findings into Security Hub
resource "aws_securityhub_product_subscription" "guardduty" {
  product_arn = "arn:aws:securityhub:${var.aws_region}::product/aws/guardduty"
  depends_on  = [aws_securityhub_account.main]
}

# Pipe Inspector findings into Security Hub
resource "aws_securityhub_product_subscription" "inspector" {
  product_arn = "arn:aws:securityhub:${var.aws_region}::product/aws/inspector"
  depends_on  = [aws_securityhub_account.main]
}
