terraform {
  backend "s3" {
    bucket         = "orderflow-tfstate-<management-account-id>"
    key            = "phase-12/prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "orderflow-tfstate-lock"
    encrypt        = true
  }
}
