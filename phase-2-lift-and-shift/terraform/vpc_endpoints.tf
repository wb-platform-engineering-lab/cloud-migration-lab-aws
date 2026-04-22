locals {
  ssm_endpoints = [
    "ssm",
    "ssmmessages",
    "ec2messages",
  ]
}

# Security group for SSM VPC endpoints — allow HTTPS inbound from the VPC
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project}-vpc-endpoints-sg"
  description = "Allow HTTPS from VPC to SSM interface endpoints"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  tags = { Name = "${var.project}-vpc-endpoints-sg" }
}

# SSM interface endpoints — allow Session Manager without NAT or internet access
resource "aws_vpc_endpoint" "ssm" {
  for_each = toset(local.ssm_endpoints)

  vpc_id              = data.aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.aws_subnets.private.ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.project}-${each.key}-endpoint" }
}
