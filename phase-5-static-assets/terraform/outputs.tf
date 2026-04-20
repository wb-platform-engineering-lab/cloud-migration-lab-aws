output "assets_bucket_name" {
  description = "S3 bucket name for static assets"
  value       = aws_s3_bucket.assets.bucket
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain — use this as the CDN base URL"
  value       = aws_cloudfront_distribution.assets.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID — needed to invalidate the cache after deploys"
  value       = aws_cloudfront_distribution.assets.id
}
