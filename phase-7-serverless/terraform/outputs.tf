output "daily_report_function_arn" {
  description = "Daily report Lambda ARN"
  value       = aws_lambda_function.daily_report.arn
}

output "send_email_function_arn" {
  description = "Email confirmation Lambda ARN"
  value       = aws_lambda_function.send_email.arn
}

output "scheduler_arn" {
  description = "EventBridge Scheduler ARN for the daily report"
  value       = aws_scheduler_schedule.daily_report.arn
}
