resource "aws_ecr_repository" "orderflow" {
  name                 = "orderflow"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "orderflow" }
}

# Keep only the 10 most recent images to control ECR storage cost
resource "aws_ecr_lifecycle_policy" "orderflow" {
  repository = aws_ecr_repository.orderflow.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
