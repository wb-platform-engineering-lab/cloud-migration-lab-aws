resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project}-ecs-tasks-sg"
  description = "Allow traffic from ALB to ECS tasks"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = data.aws_lb.main.security_groups
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-ecs-tasks-sg" }
}

resource "aws_ecs_cluster" "main" {
  name = var.project

  setting {
    name  = "containerInsights"
    value = "disabled" # Enabled adds ~$0.30/day in CloudWatch costs
  }

  tags = { Name = var.project }
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project}"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "orderflow" {
  family                   = var.project
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  # Minimum Fargate allocation: 0.25 vCPU / 0.5 GB — cheapest option (~$0.30/day per task)
  cpu    = "256" # 0.25 vCPU
  memory = "512" # 0.5 GB

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "orderflow"
    image     = "${aws_ecr_repository.orderflow.repository_url}:latest"
    essential = true

    portMappings = [{
      containerPort = 3000
      protocol      = "tcp"
    }]

    environment = [
      { name = "NODE_ENV", value = "production" },
      { name = "PORT", value = "3000" },
    ]

    secrets = [
      { name = "DATABASE_URL",    valueFrom = data.aws_secretsmanager_secret.database_url.arn },
      { name = "REDIS_URL",       valueFrom = data.aws_secretsmanager_secret.redis_url.arn },
      { name = "SESSION_SECRET",  valueFrom = data.aws_secretsmanager_secret.session_secret.arn },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "orderflow" {
  name            = "orderflow"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.orderflow.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  # Rolling deployment — ECS starts new tasks before stopping old ones
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = data.aws_subnets.private.ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ecs.arn
    container_name   = "orderflow"
    container_port   = 3000
  }

  depends_on = [aws_lb_listener_rule.ecs_http]

  tags = { Project = var.project }
}
