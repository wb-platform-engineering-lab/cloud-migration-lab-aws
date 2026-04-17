# Phase 1 — AWS Foundations

> **AWS services introduced:** VPC, IAM, S3, DynamoDB | **Daily cost:** ~$2.20/day

## Objective

Stand up the network, identity, and Terraform state backend that every subsequent phase depends on. Nothing in AWS is reachable without a VPC — this is the foundation.

## AWS services

| Service | Why we need it |
|---|---|
| **VPC** | Isolated private network for all OrderFlow resources |
| **IAM** | Identity and access control for every AWS interaction |
| **S3** | Terraform remote state storage |
| **DynamoDB** | Terraform state locking (prevents concurrent apply conflicts) |

## Terraform structure

```
terraform/
├── backend.tf       # S3 + DynamoDB state backend
├── vpc.tf           # VPC, subnets, route tables, NAT gateway
├── iam.tf           # Roles and policies for app workloads
└── variables.tf
```

## VPC design

```
10.0.0.0/16
├── Public subnets  (10.0.1.0/24, 10.0.2.0/24)   — ALB, NAT gateway
└── Private subnets (10.0.10.0/24, 10.0.11.0/24) — app servers, databases
```

## Challenges

1. Create the S3 bucket and DynamoDB lock table manually (the only console step — Terraform cannot store its own state before the bucket exists)
2. Write Terraform to provision the VPC with public and private subnets across 2 AZs
3. Add a NAT gateway in each public subnet
4. Create an IAM role for EC2 with `AmazonSSMManagedInstanceCore` (no SSH keys needed)
5. Run `terraform plan` and verify before applying
6. Tag every resource: `Environment=dev`, `Project=orderflow`

## Outcome

A VPC with public/private subnets across 2 AZs, Terraform state in S3 with locking, and IAM roles ready for Phase 2.

## Cost breakdown

| Resource | $/day |
|---|---|
| 2× NAT Gateway | $2.16 |
| S3 + DynamoDB | ~$0.04 |
| **Total** | **~$2.20** |

> **Always destroy NAT gateways when not working.** Two NAT gateways cost $1,620/year doing nothing.

```bash
cd terraform && terraform destroy -auto-approve
```

---

[Back to main README](../README.md)
