output "alerts_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarm notifications"
  value       = aws_sns_topic.alerts.arn
}

output "prometheus_endpoint" {
  description = "AMP remote write endpoint — used in kube-prometheus-stack Helm values"
  value       = aws_prometheus_workspace.orderflow.prometheus_endpoint
}

output "grafana_endpoint" {
  description = "Managed Grafana URL"
  value       = "https://${aws_grafana_workspace.orderflow.endpoint}"
}
