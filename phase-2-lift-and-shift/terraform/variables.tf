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

variable "domain" {
  description = "Base domain name for Route 53 (e.g. example.com). Leave empty to skip DNS/ACM setup."
  type        = string
  default     = ""
}
