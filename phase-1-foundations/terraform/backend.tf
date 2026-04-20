terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    # Replace REPLACE_WITH_ACCOUNT_ID with your AWS account ID
    # e.g. bucket = "orderflow-tfstate-123456789012"
    bucket         = "orderflow-tfstate-REPLACE_WITH_ACCOUNT_ID"
    key            = "phase-1/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "orderflow-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
