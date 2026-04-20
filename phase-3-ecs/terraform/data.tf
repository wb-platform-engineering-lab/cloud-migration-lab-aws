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

# Reference Phase 2 ALB target group to attach the ECS service
data "aws_lb" "main" {
  tags = { Name = "${var.project}-alb" }
}

data "aws_lb_target_group" "app" {
  name = "${var.project}-tg"
}

# RDS secret ARN from Phase 2
data "aws_secretsmanager_secret" "db_password" {
  name = "${var.project}/db-password"
}
