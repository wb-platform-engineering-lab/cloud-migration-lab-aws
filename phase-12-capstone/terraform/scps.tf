# ---------------------------------------------------------------------------
# Service Control Policies — AWS Well-Architected Framework top 10
# Applied to: Workloads OU (covers dev, staging, and prod accounts)
# Run from: management account (terraform workspace select default)
# ---------------------------------------------------------------------------

data "aws_organizations_organization" "current" {}

data "aws_organizations_organizational_units" "root" {
  parent_id = data.aws_organizations_organization.current.roots[0].id
}

locals {
  workloads_ou_id = [
    for ou in data.aws_organizations_organizational_units.root.children :
    ou.id if ou.name == "Workloads"
  ][0]
}

# ---------------------------------------------------------------------------
# SCP 1 — Deny root user actions
# WAF: Security — SEC 02 (Use strong identity controls)
# ---------------------------------------------------------------------------

resource "aws_organizations_policy" "deny_root_actions" {
  name        = "orderflow-deny-root-actions"
  description = "Prevent root user from performing any action in member accounts"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DenyRootActions"
      Effect   = "Deny"
      Action   = "*"
      Resource = "*"
      Condition = {
        StringLike = {
          "aws:PrincipalArn" = ["arn:aws:iam::*:root"]
        }
      }
    }]
  })
}

resource "aws_organizations_policy_attachment" "deny_root_actions" {
  policy_id = aws_organizations_policy.deny_root_actions.id
  target_id = local.workloads_ou_id
}

# ---------------------------------------------------------------------------
# SCP 2 — Deny leaving the Organization
# WAF: Security — SEC 01 (Implement a strong identity foundation)
# ---------------------------------------------------------------------------

resource "aws_organizations_policy" "deny_leave_org" {
  name        = "orderflow-deny-leave-org"
  description = "Prevent member accounts from leaving the Organization"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DenyLeaveOrganization"
      Effect   = "Deny"
      Action   = ["organizations:LeaveOrganization"]
      Resource = "*"
    }]
  })
}

resource "aws_organizations_policy_attachment" "deny_leave_org" {
  policy_id = aws_organizations_policy.deny_leave_org.id
  target_id = local.workloads_ou_id
}

# ---------------------------------------------------------------------------
# SCP 3 — Deny disabling CloudTrail
# WAF: Security — SEC 04 (Detect and investigate security events)
# ---------------------------------------------------------------------------

resource "aws_organizations_policy" "deny_disable_cloudtrail" {
  name        = "orderflow-deny-disable-cloudtrail"
  description = "Prevent CloudTrail from being stopped, deleted, or modified"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyDisableCloudTrail"
      Effect = "Deny"
      Action = [
        "cloudtrail:DeleteTrail",
        "cloudtrail:StopLogging",
        "cloudtrail:UpdateTrail",
        "cloudtrail:PutEventSelectors",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_organizations_policy_attachment" "deny_disable_cloudtrail" {
  policy_id = aws_organizations_policy.deny_disable_cloudtrail.id
  target_id = local.workloads_ou_id
}

# ---------------------------------------------------------------------------
# SCP 4 — Deny disabling GuardDuty
# WAF: Security — SEC 04 (Detect and investigate security events)
# ---------------------------------------------------------------------------

resource "aws_organizations_policy" "deny_disable_guardduty" {
  name        = "orderflow-deny-disable-guardduty"
  description = "Prevent GuardDuty from being disabled or its findings deleted"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyDisableGuardDuty"
      Effect = "Deny"
      Action = [
        "guardduty:DeleteDetector",
        "guardduty:DisassociateFromMasterAccount",
        "guardduty:StopMonitoringMembers",
        "guardduty:UpdateDetector",
        "guardduty:DeletePublishingDestination",
        "guardduty:DeleteThreatIntelSet",
        "guardduty:DeleteIPSet",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_organizations_policy_attachment" "deny_disable_guardduty" {
  policy_id = aws_organizations_policy.deny_disable_guardduty.id
  target_id = local.workloads_ou_id
}

# ---------------------------------------------------------------------------
# SCP 5 — Deny disabling AWS Config
# WAF: Security — SEC 04 (Detect and investigate security events)
# ---------------------------------------------------------------------------

resource "aws_organizations_policy" "deny_disable_config" {
  name        = "orderflow-deny-disable-config"
  description = "Prevent AWS Config recorder and delivery channel from being disabled"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyDisableConfig"
      Effect = "Deny"
      Action = [
        "config:DeleteConfigurationRecorder",
        "config:DeleteDeliveryChannel",
        "config:StopConfigurationRecorder",
        "config:DeleteRetentionConfiguration",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_organizations_policy_attachment" "deny_disable_config" {
  policy_id = aws_organizations_policy.deny_disable_config.id
  target_id = local.workloads_ou_id
}

# ---------------------------------------------------------------------------
# SCP 6 — Restrict to approved regions
# WAF: Security — SEC 01 / data residency and blast radius reduction
# ---------------------------------------------------------------------------

resource "aws_organizations_policy" "deny_non_approved_regions" {
  name        = "orderflow-deny-non-approved-regions"
  description = "Restrict all actions to us-east-1 and us-west-2 only"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyNonApprovedRegions"
      Effect = "Deny"
      NotAction = [
        "iam:*",
        "organizations:*",
        "support:*",
        "sts:*",
        "cloudfront:*",
        "waf:*",
        "route53:*",
        "budgets:*",
        "ce:*",
        "health:*",
      ]
      Resource = "*"
      Condition = {
        StringNotEquals = {
          "aws:RequestedRegion" = ["us-east-1", "us-west-2"]
        }
      }
    }]
  })
}

resource "aws_organizations_policy_attachment" "deny_non_approved_regions" {
  policy_id = aws_organizations_policy.deny_non_approved_regions.id
  target_id = local.workloads_ou_id
}

# ---------------------------------------------------------------------------
# SCP 7 — Deny IAM user and access key creation
# WAF: Security — SEC 02 (Enforce federated identity, no long-lived keys)
# ---------------------------------------------------------------------------

resource "aws_organizations_policy" "deny_iam_users" {
  name        = "orderflow-deny-iam-users"
  description = "Prohibit long-lived IAM users and access keys; require SSO and roles"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyIAMUsersAndKeys"
      Effect = "Deny"
      Action = [
        "iam:CreateUser",
        "iam:CreateAccessKey",
        "iam:CreateLoginProfile",
        "iam:UpdateAccessKey",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_organizations_policy_attachment" "deny_iam_users" {
  policy_id = aws_organizations_policy.deny_iam_users.id
  target_id = local.workloads_ou_id
}

# ---------------------------------------------------------------------------
# SCP 8 — Deny public S3 bucket ACLs
# WAF: Security — SEC 07 (Classify and protect your data)
# ---------------------------------------------------------------------------

resource "aws_organizations_policy" "deny_public_s3" {
  name        = "orderflow-deny-public-s3"
  description = "Prevent S3 buckets and objects from being made publicly accessible"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyPublicBucketACL"
        Effect = "Deny"
        Action = ["s3:PutBucketAcl"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = ["public-read", "public-read-write", "authenticated-read"]
          }
        }
      },
      {
        Sid    = "DenyDisableS3BlockPublicAccess"
        Effect = "Deny"
        Action = ["s3:PutBucketPublicAccessBlock"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "s3:BlockPublicAcls"       = "false"
            "s3:IgnorePublicAcls"      = "false"
            "s3:BlockPublicPolicy"     = "false"
            "s3:RestrictPublicBuckets" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "deny_public_s3" {
  policy_id = aws_organizations_policy.deny_public_s3.id
  target_id = local.workloads_ou_id
}

# ---------------------------------------------------------------------------
# SCP 9 — Require encryption at rest
# WAF: Security — SEC 08 (Protect data at rest)
# ---------------------------------------------------------------------------

resource "aws_organizations_policy" "require_encryption" {
  name        = "orderflow-require-encryption-at-rest"
  description = "Deny creation of unencrypted EBS volumes, RDS instances, and S3 objects"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyUnencryptedEBS"
        Effect   = "Deny"
        Action   = ["ec2:CreateVolume"]
        Resource = "*"
        Condition = {
          Bool = { "ec2:Encrypted" = "false" }
        }
      },
      {
        Sid      = "DenyUnencryptedRDS"
        Effect   = "Deny"
        Action   = ["rds:CreateDBInstance"]
        Resource = "*"
        Condition = {
          Bool = { "rds:StorageEncrypted" = "false" }
        }
      },
      {
        Sid      = "DenyUnencryptedS3Objects"
        Effect   = "Deny"
        Action   = ["s3:PutObject"]
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = ["AES256", "aws:kms"]
          }
        }
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "require_encryption" {
  policy_id = aws_organizations_policy.require_encryption.id
  target_id = local.workloads_ou_id
}

# ---------------------------------------------------------------------------
# SCP 10 — Deny non-approved EC2 instance types
# WAF: Cost Optimization — COST 06 (Right-size compute to workload needs)
# ---------------------------------------------------------------------------

resource "aws_organizations_policy" "deny_large_instances" {
  name        = "orderflow-deny-large-instances"
  description = "Restrict EC2 instance types to t3, t4g, and m6i families only"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DenyLargeInstances"
      Effect   = "Deny"
      Action   = ["ec2:RunInstances"]
      Resource = "arn:aws:ec2:*:*:instance/*"
      Condition = {
        StringNotLike = {
          "ec2:InstanceType" = [
            "t2.*",
            "t3.*",
            "t3a.*",
            "t4g.*",
            "m6i.large",
            "m6i.xlarge",
            "m6a.large",
            "m6a.xlarge",
          ]
        }
      }
    }]
  })
}

resource "aws_organizations_policy_attachment" "deny_large_instances" {
  policy_id = aws_organizations_policy.deny_large_instances.id
  target_id = local.workloads_ou_id
}
