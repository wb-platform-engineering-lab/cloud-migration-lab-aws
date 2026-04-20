output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.orderflow.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = aws_eks_cluster.orderflow.endpoint
}

output "cluster_certificate_authority" {
  description = "Base64-encoded cluster CA certificate"
  value       = aws_eks_cluster.orderflow.certificate_authority[0].data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN — used when creating IRSA roles for add-ons"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "kubeconfig_command" {
  description = "Run this command to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.orderflow.name} --region ${var.aws_region}"
}
