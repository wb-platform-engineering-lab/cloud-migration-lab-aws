data "aws_caller_identity" "current" {}

data "aws_vpc" "main" {
  tags = { Project = var.project }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = { Tier = "private" }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = { Tier = "public" }
}

# OIDC issuer thumbprint for IRSA
data "tls_certificate" "eks" {
  url = aws_eks_cluster.orderflow.identity[0].oidc[0].issuer
}
