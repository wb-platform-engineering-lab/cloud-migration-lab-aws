# Phase 11 — Security Hardening

> **AWS services introduced:** WAF, GuardDuty, Config, Inspector, Security Hub, Secrets Manager rotation | **Daily cost:** ~$11.95/day

## Objective

The earlier phases prioritised getting the system running. This phase hardens it: least privilege IAM, automatic secret rotation, threat detection, and a single pane of glass for all security findings.

## AWS services

| Service | Why we need it |
|---|---|
| **Secrets Manager** | Managed secret storage with automatic rotation |
| **WAF** | Blocks SQL injection, XSS, and malicious bots at the ALB |
| **GuardDuty** | ML-based detection of unusual API calls and data exfiltration |
| **Config** | Audits resource configuration — alerts on drift from baseline |
| **Inspector** | Continuous CVE scanning of ECR images |
| **Security Hub** | Aggregates GuardDuty, Config, and Inspector findings in one view |

## Terraform structure

```
terraform/
├── waf.tf           # WAF Web ACL + managed rule groups + rate limiting
├── guardduty.tf     # GuardDuty detector
├── config.tf        # Config recorder + managed rules (restricted-ssh, etc.)
├── inspector.tf     # Inspector activation for ECR
├── security_hub.tf  # Security Hub + standard integrations
├── secrets.tf       # Secrets Manager rotation for RDS password
└── variables.tf
```

## Key controls

**WAF Web ACL rules applied to the ALB:**
- `AWSManagedRulesCommonRuleSet` — SQL injection, XSS
- `AWSManagedRulesAmazonIpReputationList` — known malicious IPs
- Custom rate limit: block IPs exceeding 1,000 requests per 5 minutes

**Secrets Manager rotation:**
- RDS password rotates every 30 days automatically
- Application reads the current value from Secrets Manager on each connection — never notices the rotation

**IAM least privilege:**
- Audit every role with `aws iam generate-service-last-accessed-details`
- Replace broad managed policies with custom policies listing exact actions needed

## Challenges

1. Enable GuardDuty. Simulate a finding: make an API call from a Tor exit node (`torify`). Confirm `UnauthorizedAccess:IAMUser/TorIPCaller` appears.
2. Attach a WAF ACL to the ALB. Attempt SQL injection (`GET /orders?id=1' OR '1'='1`) — confirm WAF returns 403.
3. Enable Secrets Manager automatic rotation for the RDS password. Verify the app continues to function through a rotation cycle.
4. Enable AWS Config with `restricted-ssh` and `restricted-common-ports`. Open port 22 on a security group — confirm Config flags it as non-compliant within 15 minutes. Close it.
5. Run `generate-service-last-accessed-details` on each role. Remove permissions unused in the past 90 days.
6. Enable Inspector on ECR. Push an image with a known CVE — confirm the finding appears in Security Hub.

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

[Back to main README](../README.md)
