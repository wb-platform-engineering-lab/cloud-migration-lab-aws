# Amazon Managed Prometheus workspace
# Cost: ~$0.10/day for small workloads within free tier (10 million samples/month free)
resource "aws_prometheus_workspace" "orderflow" {
  alias = var.project
  tags  = { Name = var.project }
}
