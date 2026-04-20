# Cognito User Pool — free tier: 50,000 MAU (monthly active users)
# No cost until you exceed 50K MAU
resource "aws_cognito_user_pool" "orderflow" {
  name = var.project

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = false
    require_uppercase                = true
    temporary_password_validity_days = 7
  }

  # OPTIONAL: users may enrol TOTP MFA themselves; not required at sign-in
  mfa_configuration = "OPTIONAL"

  software_token_mfa_configuration {
    enabled = true
  }

  # Email verification message
  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Your OrderFlow verification code"
    email_message        = "Your verification code is {####}"
  }

  # Account recovery via email
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  tags = { Name = var.project }
}

# App client — used by the ALB to perform the OAuth flow
resource "aws_cognito_user_pool_client" "alb" {
  name         = "${var.project}-alb-client"
  user_pool_id = aws_cognito_user_pool.orderflow.id

  generate_secret = true # ALB requires a client secret

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  supported_identity_providers = ["COGNITO"]

  callback_urls = ["https://${var.alb_dns_name}/oauth2/idpresponse"]
  logout_urls   = ["https://${var.alb_dns_name}/logout"]

  # Token validity
  access_token_validity  = 1   # hours
  id_token_validity      = 1   # hours
  refresh_token_validity = 30  # days

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
}

# Hosted UI domain — provides the managed sign-in page
# Must be globally unique; the project + random suffix avoids collisions
resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${var.project}-auth-${substr(aws_cognito_user_pool.orderflow.id, 0, 8)}"
  user_pool_id = aws_cognito_user_pool.orderflow.id
}
