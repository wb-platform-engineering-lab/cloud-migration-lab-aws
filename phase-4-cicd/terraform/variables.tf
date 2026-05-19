variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name"
  type        = string
  default     = "orderflow"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}
