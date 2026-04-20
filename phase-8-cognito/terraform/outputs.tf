output "user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.orderflow.id
}

output "user_pool_arn" {
  description = "Cognito User Pool ARN"
  value       = aws_cognito_user_pool.orderflow.arn
}

output "app_client_id" {
  description = "App client ID — configure in ALB authentication action"
  value       = aws_cognito_user_pool_client.alb.id
}

output "app_client_secret" {
  description = "App client secret — configure in ALB authentication action"
  value       = aws_cognito_user_pool_client.alb.client_secret
  sensitive   = true
}

output "hosted_ui_domain" {
  description = "Cognito hosted UI base URL"
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com"
}
