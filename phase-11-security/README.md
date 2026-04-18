# Phase 11 — Security Hardening

> **AWS services introduced:** WAF, GuardDuty, Config, Inspector, Security Hub, Secrets Manager rotation | **Daily cost:** ~$11.95/day

---

## AWS services introduced

| Service | What it does | Why we need it |
|---|---|---|
| **Secrets Manager** | Managed secret storage with rotation | Database passwords, API keys — never in env vars or code |
| **WAF** | Web Application Firewall | Block SQL injection, XSS, and malicious bots at the ALB |
| **GuardDuty** | Threat detection | ML-based detection of unusual API calls, crypto mining, data exfiltration |
| **Security Hub** | Aggregated security findings | Single view of GuardDuty, Config, Inspector, and IAM Access Analyzer findings |
| **Config** | Resource configuration audit | Detect configuration drift (e.g., security group opened to 0.0.0.0/0) |
| **Inspector** | Vulnerability scanning | Continuous CVE scanning of ECR images and EC2 instances |

## The problem

The earlier phases prioritized getting the system running. Now we harden it. The focus is on the principle of least privilege, detection, and response.

## Key controls in this phase

**IAM: replace broad policies with scoped ones**

Every IAM role in the lab inherited `AmazonECSFullAccess` or similar managed policies for convenience. Now audit each role and replace with a custom policy that lists only the exact actions the service needs. A Lambda that sends email needs `ses:SendEmail` — nothing else.

**Secrets Manager rotation**

RDS Secrets Manager integration enables automatic password rotation. Every 30 days, Secrets Manager generates a new password, updates RDS, and updates the secret value. Your application reads the current password from Secrets Manager on each connection — it never notices the rotation.

**WAF on the ALB**

Attach a WAF Web ACL to the ALB with the AWS Managed Rules: `AWSManagedRulesCommonRuleSet` (SQL injection, XSS) and `AWSManagedRulesAmazonIpReputationList` (known malicious IPs). Add a rate-limiting rule: block IPs that exceed 1000 requests per 5 minutes.

## Challenges

1. Enable GuardDuty in the account. Simulate a finding: make an API call from a Tor exit node (use a tool like `torify`). Confirm GuardDuty generates a `UnauthorizedAccess:IAMUser/TorIPCaller` finding.
2. Attach a WAF ACL to the ALB with the AWS Managed Common Rule Set. Attempt a SQL injection (`GET /orders?id=1' OR '1'='1`) — confirm WAF blocks it with a 403.
3. Enable Secrets Manager automatic rotation for the RDS password. Verify the application continues to function through a rotation cycle.
4. Enable AWS Config with the `restricted-ssh` and `restricted-common-ports` managed rules. Open port 22 on a security group — confirm Config marks the resource as non-compliant within 15 minutes. Close the port.
5. Run `aws iam generate-service-last-accessed-details` on each IAM role. Remove any permissions that have not been used in the past 90 days.
6. Enable Inspector on ECR repositories. Push an image with a known CVE. Confirm Inspector generates a finding and the finding appears in Security Hub.

## Outcome

GuardDuty, WAF, Config, and Inspector are active. All secrets rotate automatically. Every IAM role uses a scoped custom policy. Security Hub provides a single view of all findings.

## Cost breakdown

| Resource | $/day |
|---|---|
| Phase 10 baseline | ~$9.61 |
| GuardDuty (after 30-day free trial) | ~$1.00 |
| WAF Web ACL | ~$0.17 |
| Config (~50 resources) | ~$0.20 |
| Security Hub + Inspector | ~$0.10 |
| **Total** | **~$11.08** |

> GuardDuty is free for the first 30 days per account.

```bash
cd terraform && terraform destroy -auto-approve
```

---

[Back to main README](../README.md) | [Next: Phase 12 — Multi-Environment & Capstone](../phase-12-capstone/README.md)
