# Inspector v2 — continuous CVE scanning for ECR images and EC2 instances
# Free tier: 15-day free trial per account
resource "aws_inspector2_enabler" "main" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["ECR", "EC2"]
}
