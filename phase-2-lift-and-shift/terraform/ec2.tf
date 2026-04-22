locals {
  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    db_secret_arn  = aws_secretsmanager_secret.db_password.arn
    redis_endpoint = aws_elasticache_cluster.redis.cache_nodes[0].address
    aws_region     = var.aws_region
    project        = var.project
  }))
}

resource "aws_launch_template" "app" {
  name_prefix   = "${var.project}-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = "t2.micro" # Free tier: 750 hrs/month for 12 months (was t3.small)

  user_data = local.user_data

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.app.id]
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${var.project}-app"
      Project = var.project
    }
  }
}

resource "aws_autoscaling_group" "app" {
  name                = "${var.project}-asg"
  min_size            = 1
  max_size            = 2
  desired_capacity    = 1 # 1 instance to stay within free tier 750 hrs/month
  vpc_zone_identifier = data.aws_subnets.private.ids

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.app.arn]

  health_check_type         = "ELB"
  health_check_grace_period = 300

  tag {
    key                 = "Project"
    value               = var.project
    propagate_at_launch = true
  }
}
