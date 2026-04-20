output "alb_dns_name" {
  description = "ALB DNS name — access OrderFlow here if no domain is configured"
  value       = aws_lb.main.dns_name
}

output "db_instance_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = aws_db_instance.main.endpoint
}

output "db_secret_arn" {
  description = "Secrets Manager ARN for the database credentials"
  value       = aws_secretsmanager_secret.db_password.arn
}

output "redis_endpoint" {
  description = "ElastiCache Redis endpoint"
  value       = aws_elasticache_cluster.redis.cache_nodes[0].address
}

output "target_group_arn" {
  description = "ALB target group ARN — used to verify health checks"
  value       = aws_lb_target_group.app.arn
}
