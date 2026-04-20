output "guardduty_detector_id" {
  description = "GuardDuty detector ID"
  value       = aws_guardduty_detector.main.id
}

output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = aws_wafv2_web_acl.main.arn
}

output "config_bucket_name" {
  description = "S3 bucket for Config delivery"
  value       = aws_s3_bucket.config.bucket
}
