resource "aws_guardduty_detector" "main" {
  enable = true

  # Publish findings every 15 minutes — default 6 hours is too slow for a lab
  finding_publishing_frequency = "FIFTEEN_MINUTES"

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
