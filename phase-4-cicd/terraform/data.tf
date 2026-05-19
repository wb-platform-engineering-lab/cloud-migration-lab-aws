data "aws_caller_identity" "current" {}

data "aws_iam_role" "ecs_task_execution" {
  name = "${var.project}-ecs-task-execution"
}

data "aws_iam_role" "ecs_task" {
  name = "${var.project}-ecs-task"
}
