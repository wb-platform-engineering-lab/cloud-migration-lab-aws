# Phase 12 — Multi-Environment & Capstone

> **AWS services introduced:** AWS Organizations, Control Tower, Service Catalog | **Daily cost:** ~$31–35/day

## Objective

Promote OrderFlow to a production-grade, three-account AWS environment. Demonstrate full GitOps promotion, cross-account security, incident response, and cost visibility — the capstone scenario simulates Black Friday readiness.

## AWS services

| Service | Why we need it |
|---|---|
| **AWS Organizations** | Separate AWS accounts for dev/staging/prod with consolidated billing |
| **Control Tower** | Enforces account-level security baseline automatically |
| **Service Catalog** | Self-service infrastructure provisioning without Terraform knowledge |

## Terraform structure

```
terraform/
├── organizations.tf  # AWS Organizations + OUs
├── accounts.tf       # dev, staging, prod, audit, log-archive accounts
├── control_tower.tf  # Landing zone + guardrails
├── pipelines.tf      # Cross-account promotion pipeline (dev → staging → prod)
└── variables.tf
```

## Account structure

```
Management Account
├── Audit Account          — CloudTrail logs, Security Hub aggregation
├── Log Archive Account    — Centralised CloudWatch logs
└── Workloads OU
    ├── dev Account        — Shared by developers for experimentation
    ├── staging Account    — Production-like, used for pre-release validation
    └── prod Account       — Customer traffic only, tightest guardrails
```

## The capstone scenario

Six months have passed. Black Friday is in two weeks. Demonstrate:

1. **GitOps promotion pipeline**: `git push` → CI → dev EKS → staging (manual approval) → prod — fully automated, no console clicks
2. **Cross-account security**: GuardDuty and WAF active in all three accounts. Security Hub aggregates findings into the audit account.
3. **Incident simulation**: RDS Multi-AZ failover. Orders must continue with <60 seconds of elevated error rate. Show the X-Ray trace and CloudWatch alarm.
4. **Cost report**: Cost Explorer breakdown by account, service, and environment. Identify the top three cost drivers. Propose one reduction (e.g., Savings Plan for ECS Fargate).
5. **Day-one experience**: A new engineer runs `git clone`, `docker compose up`, places an order — without any AWS access or tribal knowledge.

## Cost breakdown

| Account | Key resources | $/day |
|---|---|---|
| dev | 1 NAT GW, EKS, 1× t3.small, RDS Single-AZ | ~$5 |
| staging | 2 NAT GW, EKS, 2× t3.medium, RDS Multi-AZ, ElastiCache | ~$10 |
| prod | 2 NAT GW, EKS, 2× t3.medium, RDS Multi-AZ, ElastiCache, WAF | ~$11 |
| shared | GuardDuty, Config, Security Hub, CloudTrail (3 accounts) | ~$5 |
| **Total** | | **~$31–35/day** |

> Run Phase 12 in sprint mode — provision, complete the capstone, destroy within 2–3 days. A full run costs ~$70–100.

```bash
# Destroy each account's resources before decommissioning
cd terraform && terraform destroy -auto-approve
```

---

[Back to main README](../README.md)
