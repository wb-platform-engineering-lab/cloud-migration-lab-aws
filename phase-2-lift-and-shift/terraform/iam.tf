data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${var.project}-app-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = { Project = var.project }
}

# SSM Session Manager — no SSH keys needed
resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Secrets Manager — read the DB credentials secret
resource "aws_iam_role_policy" "app_secrets" {
  name = "${var.project}-app-secrets"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.db_password.arn
    }]
  })
}

# RDS — describe instances to resolve the endpoint at boot
resource "aws_iam_role_policy" "app_rds_describe" {
  name = "${var.project}-app-rds-describe"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "rds:DescribeDBInstances"
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project}-app-instance-profile"
  role = aws_iam_role.app.name
}
