output "ecr_repository_url" {
  description = "ECR repository URL — tag and push images here"
  value       = aws_ecr_repository.orderflow.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.orderflow.name
}
