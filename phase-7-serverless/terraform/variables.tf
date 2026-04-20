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

variable "report_recipients" {
  description = "Email addresses to receive daily sales reports (must be SES-verified)"
  type        = list(string)
  default     = []
}
