output "workspace" {
  description = "Current Terraform workspace (environment)"
  value       = terraform.workspace
}

output "github_deploy_role_arn" {
  description = "IAM role ARN for GitHub Actions — add as a repository secret"
  value       = try(aws_iam_role.github_deploy[0].arn, "GitHub OIDC not configured — set github_org variable")
}
