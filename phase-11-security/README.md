# Phase 11 — Security Hardening

> **AWS services introduced:** WAF, GuardDuty, Config, Inspector, Security Hub, Secrets Manager rotation | **Daily cost:** ~$5.64/day

---

## AWS services introduced

| Service | What it does | Why we need it |
|---|---|---|
| **Secrets Manager** | Managed secret storage with automatic rotation | Database passwords, API keys — never in env vars or code |
| **WAF** | Web Application Firewall | Block SQL injection, XSS, and malicious bots at the ALB |
| **GuardDuty** | Threat detection | ML-based detection of unusual API calls, crypto mining, data exfiltration |
| **Security Hub** | Aggregated security findings | Single view of GuardDuty, Config, Inspector, and IAM Access Analyzer findings |
| **Config** | Resource configuration audit | Detect configuration drift (e.g., a security group opened to 0.0.0.0/0) |
| **Inspector** | Vulnerability scanning | Continuous CVE scanning of ECR images and running EKS nodes |

## The problem

The earlier phases prioritised getting the system running. Now we harden it. Every IAM role has broad managed policies for convenience. Secrets are static and never rotated. There is no detection layer — if an attacker exfiltrates credentials, there is nothing to alert on.

The three principles applied in this phase:

- **Least privilege** — every role has only the permissions it uses
- **Detect** — GuardDuty and Config alert on anomalies and drift
- **Rotate** — secrets change automatically; a leaked credential has a short window

---

## Challenge 1 — Enable GuardDuty and simulate a finding

**Goal:** Enable GuardDuty in the account. Generate a finding by simulating suspicious API activity. Confirm the finding appears in the console and Security Hub.

### Step 1: Enable GuardDuty via Terraform

Create `phase-11-security/terraform/guardduty.tf`:

```hcl
resource "aws_guardduty_detector" "main" {
  enable = true

  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs {
        enable = true
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  tags = { Name = "${var.project}-guardduty" }
}
```

Apply:

```bash
cd phase-11-security/terraform
terraform init
terraform apply -auto-approve
```

### Step 2: Verify GuardDuty is active

```bash
aws guardduty list-detectors --query 'DetectorIds[0]' --output text
```

Expected: a detector ID like `abc1234567890def1234567890`.

```bash
DETECTOR_ID=$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text)

aws guardduty get-detector \
  --detector-id "$DETECTOR_ID" \
  --query '{Status:Status,FindingPublishingFrequency:FindingPublishingFrequency}' \
  --output table
```

Expected:

```
--------------------------------------------------
|                   GetDetector                  |
+-----------------------------+------------------+
|  FindingPublishingFrequency |  SIX_HOURS       |
|  Status                     |  ENABLED         |
+-----------------------------+------------------+
```

### Step 3: Generate a sample finding

AWS provides a built-in API to generate realistic sample findings without needing real attack infrastructure:

```bash
aws guardduty create-sample-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-types \
    "UnauthorizedAccess:IAMUser/TorIPCaller" \
    "Recon:IAMUser/MaliciousIPCaller" \
    "CryptoCurrency:EC2/BitcoinTool.B"
```

### Step 4: Retrieve the findings

```bash
# List findings — may take up to 5 minutes to appear
aws guardduty list-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-criteria '{"Criterion":{"severity":{"Gte":4}}}' \
  --query 'FindingIds[:3]' \
  --output table
```

Fetch the details of one finding:

```bash
FINDING_ID=$(aws guardduty list-findings \
  --detector-id "$DETECTOR_ID" \
  --query 'FindingIds[0]' \
  --output text)

aws guardduty get-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-ids "$FINDING_ID" \
  --query 'Findings[0].{Type:Type,Severity:Severity,Description:Description}' \
  --output table
```

Expected output:

```
-----------------------------------------------------------------------
|                           GetFindings                               |
+-------------+-------------------------------------------------------+
|  Description|  APIs commonly used to discover the users, groups,...  |
|  Severity   |  5.0                                                   |
|  Type       |  Recon:IAMUser/MaliciousIPCaller                      |
+-------------+-------------------------------------------------------+
```

### Step 5: Set finding publishing frequency to 15 minutes for the lab

The default 6-hour publishing delay is too slow for a lab. Update it:

```hcl
resource "aws_guardduty_detector" "main" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  # ... rest unchanged
}
```

```bash
terraform apply -auto-approve
```

---

## Challenge 2 — Attach a WAF Web ACL to the ALB

**Goal:** Create a WAF Web ACL with AWS managed rules blocking SQL injection and XSS. Add a rate-limiting rule. Verify that a SQL injection request is blocked with a 403.

### Step 1: Create the WAF Web ACL

Create `phase-11-security/terraform/waf.tf`:

```hcl
data "aws_lb" "main" {
  tags = { Name = "${var.project}-alb" }
}

resource "aws_wafv2_web_acl" "main" {
  name  = "${var.project}-waf"
  scope = "REGIONAL" # REGIONAL for ALB; CLOUDFRONT for CloudFront

  default_action {
    allow {}
  }

  # Rule 1: AWS Managed Common Rule Set — blocks SQLi, XSS, LFI, RCE
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {} # Use the rule group's own actions (Block)
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: Known malicious IP reputation list
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesAmazonIpReputationList"
      sampled_requests_enabled   = true
    }
  }

  # Rule 3: Rate limiting — block IPs exceeding 1000 requests per 5 minutes
  rule {
    name     = "RateLimitRule"
    priority = 3

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitRule"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project}-waf"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${var.project}-waf" }
}

# Associate the Web ACL with the ALB
resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = data.aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}

# Enable WAF logging to CloudWatch Logs
resource "aws_cloudwatch_log_group" "waf" {
  # WAF log group names must start with aws-waf-logs-
  name              = "aws-waf-logs-${var.project}"
  retention_in_days = 7
}

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.main.arn
}
```

Apply:

```bash
terraform apply -auto-approve
```

### Step 2: Test that a SQL injection is blocked

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names "${var.project}-alb" \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

# Attempt SQL injection in query string — WAF should block with 403
curl -si "http://${ALB_DNS}/orders?id=1'+OR+'1'='1" | head -3
```

Expected:

```
HTTP/1.1 403 Forbidden
server: awselb/2.0
```

Without WAF, this request would reach your database layer. Now it is blocked at the edge.

### Step 3: Verify WAF metrics in CloudWatch

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/WAFV2 \
  --metric-name BlockedRequests \
  --dimensions \
    Name=WebACL,Value="${var.project}-waf" \
    Name=Rule,Value=AWSManagedRulesCommonRuleSet \
    Name=Region,Value=us-east-1 \
  --start-time "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 \
  --statistics Sum \
  --output table
```

Expected: 1 blocked request from the SQL injection test.

---

## Challenge 3 — Enable Secrets Manager automatic rotation

**Goal:** Enable automatic 30-day rotation for the RDS password. Verify the application continues to function through a manual rotation cycle.

### Step 1: Enable rotation in Terraform

Update `phase-2-lift-and-shift/terraform/rds.tf` — add rotation to the secret:

```hcl
resource "aws_secretsmanager_secret_rotation" "db_password" {
  secret_id           = aws_secretsmanager_secret.db_password.id
  rotation_lambda_arn = aws_lambda_function.rds_rotation.arn

  rotation_rules {
    automatically_after_days = 30
  }
}
```

Create `phase-11-security/terraform/secrets_rotation.tf`:

```hcl
data "aws_secretsmanager_secret" "db_password" {
  name = "${var.project}/db-password"
}

data "aws_db_instance" "main" {
  db_instance_identifier = "${var.project}-postgres"
}

# IAM role for the rotation Lambda
resource "aws_iam_role" "rotation_lambda" {
  name = "${var.project}-rotation-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rotation_lambda_basic" {
  role       = aws_iam_role.rotation_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "rotation_lambda_permissions" {
  name = "rotation-permissions"
  role = aws_iam_role.rotation_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage",
        ]
        Resource = data.aws_secretsmanager_secret.db_password.arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetRandomPassword"]
        Resource = "*"
      }
    ]
  })
}

# Use the AWS-provided managed rotation Lambda for RDS PostgreSQL single-user rotation
# This is the recommended approach — avoids writing rotation logic yourself
resource "aws_serverlessapplicationrepository_cloudformation_stack" "rds_rotation" {
  name           = "${var.project}-rds-rotation"
  application_id = "arn:aws:serverlessrepo:us-east-1:297356227824:applications/SecretsManagerRDSPostgreSQLRotationSingleUser"
  capabilities   = ["CAPABILITY_IAM", "CAPABILITY_RESOURCE_POLICY"]

  parameters = {
    endpoint            = "https://secretsmanager.${var.aws_region}.amazonaws.com"
    functionName        = "${var.project}-rds-rotation"
    vpcSubnetIds        = join(",", data.aws_subnets.private.ids)
    vpcSecurityGroupIds = aws_security_group.rotation_lambda.id
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = { Tier = "private" }
}

data "aws_vpc" "main" {
  tags = { Project = var.project }
}

resource "aws_security_group" "rotation_lambda" {
  name        = "${var.project}-rotation-lambda-sg"
  description = "Rotation Lambda — allow HTTPS outbound to Secrets Manager VPC endpoint"
  vpc_id      = data.aws_vpc.main.id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  tags = { Name = "${var.project}-rotation-lambda-sg" }
}

# Enable rotation on the secret
resource "aws_secretsmanager_secret_rotation" "db_password" {
  secret_id           = data.aws_secretsmanager_secret.db_password.id
  rotation_lambda_arn = aws_serverlessapplicationrepository_cloudformation_stack.rds_rotation.outputs["RotationLambdaARN"]

  rotation_rules {
    automatically_after_days = 30
  }
}
```

Apply:

```bash
terraform apply -auto-approve
```

### Step 2: Trigger a manual rotation

```bash
SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id "${var.project}/db-password" \
  --query ARN --output text)

aws secretsmanager rotate-secret --secret-id "$SECRET_ARN"
```

Expected:

```json
{
  "ARN": "arn:aws:secretsmanager:us-east-1:...:secret:orderflow/db-password-...",
  "Name": "orderflow/db-password",
  "VersionId": "a1b2c3d4-..."
}
```

### Step 3: Verify the application is unaffected

The rotation Lambda updates the RDS password **and** updates the secret value atomically. The application reads the password fresh from Secrets Manager on each new connection — it never caches credentials longer than a connection pool lifetime.

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names "${var.project}-alb" \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

# Run 10 requests during and after rotation — all should succeed
for i in $(seq 1 10); do
  STATUS=$(curl -so /dev/null -w "%{http_code}" "http://${ALB_DNS}/health")
  echo "Request $i: $STATUS"
  sleep 3
done
```

Expected — all 200:

```
Request 1: 200
Request 2: 200
...
Request 10: 200
```

### Step 4: Confirm the new password version

```bash
aws secretsmanager list-secret-version-ids \
  --secret-id "${var.project}/db-password" \
  --query 'Versions[*].{ID:VersionId,Stages:VersionStages}' \
  --output table
```

Expected — two versions, one `AWSCURRENT` and one `AWSPREVIOUS`:

```
-----------------------------------------
|       ListSecretVersionIds            |
+-------------------------------+-------+
|  ID                           | Stages|
+-------------------------------+-------+
|  a1b2c3d4-...                 | AWSCURRENT  |
|  z9y8x7w6-...                 | AWSPREVIOUS |
+-------------------------------+-------+
```

---

## Challenge 4 — AWS Config: detect configuration drift

**Goal:** Enable AWS Config with managed rules that detect open SSH ports and unrestricted security groups. Open port 22 on a security group — confirm Config flags it as non-compliant within 15 minutes. Close the port.

### Step 1: Enable Config via Terraform

Create `phase-11-security/terraform/config.tf`:

```hcl
# S3 bucket for Config delivery — required before enabling the recorder
resource "aws_s3_bucket" "config" {
  bucket        = "${var.project}-config-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = { Name = "${var.project}-config" }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "config" {
  bucket = aws_s3_bucket.config.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSConfigBucketPermissionsCheck"
        Effect = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.config.arn
      },
      {
        Sid    = "AWSConfigBucketDelivery"
        Effect = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.config.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

data "aws_caller_identity" "current" {}

# IAM role for Config
resource "aws_iam_role" "config" {
  name = "${var.project}-config"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "config.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# Configuration recorder
resource "aws_config_configuration_recorder" "main" {
  name     = var.project
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

# Delivery channel — sends snapshots and change notifications to S3
resource "aws_config_delivery_channel" "main" {
  name           = var.project
  s3_bucket_name = aws_s3_bucket.config.bucket

  depends_on = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.main]
}

# ── Managed rules ──────────────────────────────────────────────────────────────

# Flag security groups with port 22 open to 0.0.0.0/0
resource "aws_config_config_rule" "restricted_ssh" {
  name = "restricted-ssh"

  source {
    owner             = "AWS"
    source_identifier = "INCOMING_SSH_DISABLED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# Flag security groups with common ports open to 0.0.0.0/0
resource "aws_config_config_rule" "restricted_common_ports" {
  name = "restricted-common-ports"

  source {
    owner             = "AWS"
    source_identifier = "RESTRICTED_INCOMING_TRAFFIC"
  }

  input_parameters = jsonencode({
    blockedPort1 = "22"
    blockedPort2 = "3389"
    blockedPort3 = "3306"
    blockedPort4 = "5432"
    blockedPort5 = "6379"
  })

  depends_on = [aws_config_configuration_recorder_status.main]
}

# Flag RDS instances without encryption at rest
resource "aws_config_config_rule" "rds_encryption" {
  name = "rds-storage-encrypted"

  source {
    owner             = "AWS"
    source_identifier = "RDS_STORAGE_ENCRYPTED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# Flag S3 buckets with public read access
resource "aws_config_config_rule" "s3_bucket_public_read" {
  name = "s3-bucket-public-read-prohibited"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}
```

Apply:

```bash
terraform apply -auto-approve
```

### Step 2: Open port 22 on the app security group (intentional misconfiguration)

```bash
# Get the app security group ID
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=orderflow-app-sg" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

# Open SSH from the internet — this is the misconfiguration
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0
```

### Step 3: Wait for Config to detect non-compliance

Config evaluates rules when resources change. This triggers within a few minutes:

```bash
# Poll until the rule reports NON_COMPLIANT
watch -n 30 "aws configservice get-compliance-details-by-config-rule \
  --config-rule-name restricted-ssh \
  --compliance-types NON_COMPLIANT \
  --query 'EvaluationResults[*].{Resource:EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId,Compliance:ComplianceType}' \
  --output table"
```

Expected (within 5–10 minutes):

```
-------------------------------------------------------
|    GetComplianceDetailsByConfigRule                 |
+---------------------+-------------------------------+
|  Compliance         |  Resource                     |
+---------------------+-------------------------------+
|  NON_COMPLIANT      |  sg-0abc123def456789          |
+---------------------+-------------------------------+
```

### Step 4: Remediate and verify compliance

```bash
# Close port 22
aws ec2 revoke-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0

# Trigger re-evaluation
aws configservice start-config-rules-evaluation \
  --config-rule-names restricted-ssh

# Verify COMPLIANT
sleep 60
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name restricted-ssh \
  --compliance-types NON_COMPLIANT \
  --query 'EvaluationResults | length(@)'
```

Expected: `0` — no non-compliant resources.

---

## Challenge 5 — IAM least privilege: remove unused permissions

**Goal:** Use IAM Access Advisor to identify permissions that haven't been used in 90 days. Generate scoped replacement policies for each role.

### Step 1: Generate last-accessed data for each role

```bash
# Get all orderflow IAM roles
ROLES=$(aws iam list-roles \
  --query "Roles[?contains(RoleName,'orderflow')].RoleName" \
  --output text)

for ROLE in $ROLES; do
  echo "=== $ROLE ==="
  JOB_ID=$(aws iam generate-service-last-accessed-details \
    --arn "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/$ROLE" \
    --query JobId --output text)

  # Wait for the job to complete
  sleep 5

  aws iam get-service-last-accessed-details \
    --job-id "$JOB_ID" \
    --query 'ServicesLastAccessed[?TotalAuthenticatedEntities==`0`].ServiceName' \
    --output text
done
```

Expected output — services never used by each role:

```
=== orderflow-ecs-task ===
Amazon CloudFormation
Amazon DynamoDB
AWS Systems Manager
...
=== orderflow-lambda ===
Amazon EC2
Amazon EKS
...
```

### Step 2: Review the ECS task role and scope it down

The ECS task role was created with broad Secrets Manager access. Let us scope it to only the secrets this specific service needs.

Check what the role currently has:

```bash
aws iam list-role-policies --role-name orderflow-ecs-task
aws iam list-attached-role-policies --role-name orderflow-ecs-task
```

Replace the broad policy in `phase-3-ecs/terraform/iam.tf` with a scoped one:

```hcl
# Before (too broad):
resource "aws_iam_role_policy" "ecs_task_secrets" {
  policy = jsonencode({
    Statement = [{
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:orderflow/*"
    }]
  })
}

# After (scoped to exactly one secret):
resource "aws_iam_role_policy" "ecs_task_secrets" {
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDatabaseSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = data.aws_secretsmanager_secret.db_password.arn
      },
      {
        Sid      = "PublishOrderEvents"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = data.aws_sns_topic.order_events.arn
      }
    ]
  })
}
```

Apply:

```bash
terraform apply -auto-approve
```

### Step 3: Verify the scoped role still works

```bash
# The app must still be able to read its database credentials
curl -s "http://${ALB_DNS}/health" | jq .db
```

Expected: `"ok"` — the application functions with the tighter policy.

### Step 4: Check IAM Access Analyzer

```bash
# Enable IAM Access Analyzer to find resources shared with external principals
aws accessanalyzer create-analyzer \
  --analyzer-name "${var.project}-analyzer" \
  --type ACCOUNT

# List any findings (externally accessible resources)
aws accessanalyzer list-findings \
  --analyzer-arn "arn:aws:accessanalyzer:us-east-1:$(aws sts get-caller-identity --query Account --output text):analyzer/${var.project}-analyzer" \
  --query 'findings[*].{Resource:resource,Status:status,ResourceType:resourceType}' \
  --output table
```

Any finding here means a resource (S3 bucket, IAM role, KMS key) is accessible from outside your account. Investigate and remediate each one.

---

## Challenge 6 — Inspector and Security Hub

**Goal:** Enable Security Hub to aggregate findings from all sources. Enable Inspector on ECR. Push an image and confirm a CVE finding appears.

### Step 1: Enable Security Hub

Create `phase-11-security/terraform/security_hub.tf`:

```hcl
resource "aws_securityhub_account" "main" {}

# Enable AWS Foundational Security Best Practices standard
resource "aws_securityhub_standards_subscription" "fsbp" {
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}

# Enable CIS AWS Foundations Benchmark
resource "aws_securityhub_standards_subscription" "cis" {
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/cis-aws-foundations-benchmark/v/1.2.0"
  depends_on    = [aws_securityhub_account.main]
}

# Connect GuardDuty findings to Security Hub
resource "aws_securityhub_product_subscription" "guardduty" {
  product_arn = "arn:aws:securityhub:${var.aws_region}::product/aws/guardduty"
  depends_on  = [aws_securityhub_account.main]
}

# Connect Inspector findings to Security Hub
resource "aws_securityhub_product_subscription" "inspector" {
  product_arn = "arn:aws:securityhub:${var.aws_region}::product/aws/inspector"
  depends_on  = [aws_securityhub_account.main]
}
```

Apply:

```bash
terraform apply -auto-approve
```

### Step 2: Enable Inspector for ECR

```hcl
# inspector.tf
resource "aws_inspector2_enabler" "main" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["ECR", "EC2"]
}
```

Apply:

```bash
terraform apply -auto-approve
```

### Step 3: Push an image with a known CVE

Pull a deliberately old image that contains known vulnerabilities:

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/orderflow"

# Pull an old Node.js image with known CVEs
docker pull node:14-slim
docker tag node:14-slim "${ECR_URI}:vuln-test"

aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin \
    "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

docker push "${ECR_URI}:vuln-test"
```

### Step 4: Check Inspector findings

Inspector scans the image within 1–2 minutes of the push:

```bash
# Wait 2 minutes, then check for findings
sleep 120

aws inspector2 list-findings \
  --filter-criteria '{
    "ecrImageRepositoryName": [{"comparison":"EQUALS","value":"orderflow"}],
    "severity": [{"comparison":"EQUALS","value":"HIGH"},{"comparison":"EQUALS","value":"CRITICAL"}]
  }' \
  --query 'findings[:5].{CVE:packageVulnerabilityDetails.vulnerabilityId,Severity:severity,Package:packageVulnerabilityDetails.vulnerablePackages[0].name}' \
  --output table
```

Expected:

```
----------------------------------------------------------------
|                        ListFindings                          |
+------+-------------------+-----------------------------------+
|  CVE               |  Package     |  Severity               |
+--------------------+--------------+-------------------------+
|  CVE-2023-XXXXX   |  openssl     |  HIGH                   |
|  CVE-2023-YYYYY   |  libcurl     |  CRITICAL               |
+--------------------+--------------+-------------------------+
```

### Step 5: View aggregated findings in Security Hub

```bash
aws securityhub get-findings \
  --filters '{
    "SeverityLabel":[{"Value":"CRITICAL","Comparison":"EQUALS"}],
    "RecordState":[{"Value":"ACTIVE","Comparison":"EQUALS"}]
  }' \
  --query 'Findings[:5].{Title:Title,Severity:Severity.Label,Source:ProductArn}' \
  --output table
```

Security Hub now shows a unified view of findings from GuardDuty, Config, and Inspector in a single pane of glass.

Clean up the vulnerable image:

```bash
aws ecr batch-delete-image \
  --repository-name orderflow \
  --image-ids imageTag=vuln-test
```

---

## AWS concept: the shared responsibility model

AWS secures the infrastructure. You are responsible for:

| Your responsibility | How this phase addresses it |
|---|---|
| IAM permissions | Least-privilege scoped policies (Challenge 5) |
| Secret rotation | Automated 30-day rotation (Challenge 3) |
| Vulnerability management | Inspector continuous scanning (Challenge 6) |
| Network security | WAF + security group rules (Challenges 2, 4) |
| Threat detection | GuardDuty (Challenge 1) |
| Compliance monitoring | Config managed rules (Challenge 4) |

---

## Outcome

GuardDuty, WAF, Config, and Inspector are active. All secrets rotate automatically every 30 days. Every IAM role uses a scoped custom policy with only the permissions it actively uses. Security Hub provides a single aggregated view of all findings across all services.

## Cost breakdown

| Resource | $/day |
|---|---|
| Phase 10 baseline (free-tier optimised) | ~$5.23 |
| GuardDuty (30-day free trial, then ~$1.00/day) | ~$0 |
| WAF Web ACL + rules | ~$0.17 |
| Config (~50 resources) | ~$0.20 |
| Inspector + Security Hub | ~$0.04 |
| **Total during free trial** | **~$5.64** |

> GuardDuty is **free for the first 30 days** per AWS account. After the trial, expect ~$1.00/day for a small account. Complete this phase within the trial window.

```bash
cd terraform && terraform destroy -auto-approve
```

---

[Back to main README](../README.md) | [Next: Phase 12 — Multi-Environment & Capstone](../phase-12-capstone/README.md)
