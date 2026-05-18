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

# Reference Phase 2 ALB
data "aws_lb" "main" {
  tags = { Name = "${var.project}-alb" }
}

# Reference Phase 2 HTTP listener to attach a forwarding rule for ECS
data "aws_lb_listener" "http" {
  load_balancer_arn = data.aws_lb.main.arn
  port              = 80
}

data "aws_secretsmanager_secret" "database_url" {
  name = "${var.project}/database-url"
}

data "aws_secretsmanager_secret" "redis_url" {
  name = "${var.project}/redis-url"
}

data "aws_secretsmanager_secret" "session_secret" {
  name = "${var.project}/session-secret"
}
