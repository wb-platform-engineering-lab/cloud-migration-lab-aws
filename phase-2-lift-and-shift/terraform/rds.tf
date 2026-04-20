resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.project}/db-password"
  recovery_window_in_days = 0 # Allow immediate deletion in dev

  tags = { Name = "${var.project}-db-password" }
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db_password.id
  secret_string = jsonencode({
    username = "orderflow"
    password = random_password.db.result
    dbname   = "orderflow"
  })
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnet-group"
  subnet_ids = data.aws_subnets.private.ids

  tags = { Name = "${var.project}-db-subnet-group" }
}

# Free-tier eligible: db.t3.micro, Single-AZ, 20 GB storage
# AWS free tier: 750 hrs/month of db.t2.micro or db.t3.micro for 12 months
# Original spec was db.t3.small Multi-AZ ($1.63/day) — this costs ~$0.41/day
resource "aws_db_instance" "main" {
  identifier        = "${var.project}-postgres"
  engine            = "postgres"
  engine_version    = "15"
  instance_class    = "db.t3.micro" # Free tier eligible (was db.t3.small)
  allocated_storage = 20
  storage_encrypted = true

  db_name  = "orderflow"
  username = "orderflow"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Single-AZ — free tier does not include Multi-AZ standby
  # Switch multi_az = true when you want to run the Phase 2 failover challenge
  multi_az = false

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  deletion_protection = false
  skip_final_snapshot = true

  tags = { Name = "${var.project}-postgres" }
}
