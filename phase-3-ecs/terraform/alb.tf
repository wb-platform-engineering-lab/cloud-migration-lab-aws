resource "aws_lb_target_group" "ecs" {
  name        = "${var.project}-ecs-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.main.id
  target_type = "ip" # Required for Fargate awsvpc network mode

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.project}-ecs-tg" }
}

# Override the HTTP listener default action to forward to ECS
# (phase-2 HTTP listener redirects to HTTPS; add a direct forward for non-HTTPS setups)
resource "aws_lb_listener_rule" "ecs_http" {
  listener_arn = data.aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ecs.arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}
