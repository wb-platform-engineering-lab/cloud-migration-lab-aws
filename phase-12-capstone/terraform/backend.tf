terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "orderflow-tfstate-REPLACE_WITH_ACCOUNT_ID"
    key            = "phase-12/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "orderflow-tfstate-lock"
    encrypt        = true
    # Terraform workspaces automatically prefix the key with env:/<workspace>/
    # so dev state lives at env:/dev/phase-12/terraform.tfstate
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
