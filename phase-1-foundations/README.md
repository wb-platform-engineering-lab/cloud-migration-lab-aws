# Phase 1 — AWS Foundations

> **AWS services introduced:** VPC, IAM, S3, DynamoDB | **Daily cost:** ~$2.20/day

---

## AWS services introduced

| Service | What it does | Why we need it |
|---|---|---|
| **VPC** | Isolated private network | Nothing in AWS is reachable without a VPC — it is the foundation for everything |
| **IAM** | Identity and access management | Every AWS resource interaction requires an identity and a policy |
| **S3** | Object storage | Stores Terraform state — but also used in every subsequent phase |
| **EC2** (baseline) | Virtual machines | The starting point before we containerize |

## The problem

You cannot just start deploying to AWS. You need a network your resources will live in, identities that control who can do what, and a place to store Terraform state that is not your laptop.

## Approach: infrastructure as code from day one

Every resource in this lab is created with Terraform. Never click in the console to create production resources — the console does not version-control what you did or why.

```
phase-1-foundations/
├── terraform/
│   ├── backend.tf          # S3 + DynamoDB state backend
│   ├── vpc.tf              # VPC, subnets, route tables, NAT gateway
│   ├── iam.tf              # Roles and policies for app workloads
│   └── variables.tf
└── README.md
```

**VPC design:**

```
10.0.0.0/16
├── Public subnets (10.0.1.0/24, 10.0.2.0/24)   — ALB, NAT gateway
└── Private subnets (10.0.10.0/24, 10.0.11.0/24) — app servers, databases
```

Public subnets hold load balancers and NAT gateways. Application servers and databases live in private subnets with no direct internet access — they reach the internet through the NAT gateway when needed (e.g., to pull npm packages), but nothing outside can reach them directly.

**State backend:**

```hcl
terraform {
  backend "s3" {
    bucket         = "orderflow-tfstate-<account-id>"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "orderflow-tfstate-lock"
    encrypt        = true
  }
}
```

The DynamoDB table provides state locking — if two engineers run `terraform apply` simultaneously, one waits rather than corrupting the state file.

## Challenges

1. Create the S3 bucket and DynamoDB lock table manually (this is the one thing you do in the console — because Terraform cannot store its own state before the bucket exists)
2. Write Terraform to provision the VPC with public and private subnets across 2 AZs
3. Add a NAT gateway in each public subnet so private resources can reach the internet
4. Create an IAM role for EC2 instances with `AmazonSSMManagedInstanceCore` so you can connect without SSH keys
5. Run `terraform plan` and verify all resources before applying
6. Tag every resource with `Environment=dev` and `Project=orderflow`

## AWS concept: Availability Zones

Every AWS region contains multiple Availability Zones — physically separate data centres within the same region. Spreading resources across 2 AZs means a data centre failure does not take down your application. Always provision at least 2 AZs for anything that needs to survive.

## Outcome

A VPC with public/private subnets across 2 AZs, Terraform state in S3 with locking, and IAM roles ready for the workloads in Phase 2.

## Cost breakdown

| Resource | $/day |
|---|---|
| 2× NAT Gateway | $2.16 |
| S3 + DynamoDB | ~$0.04 |
| **Total** | **~$2.20** |

> **Always destroy NAT gateways when done.** Two NAT gateways cost $1,620/year doing nothing.

```bash
cd terraform && terraform destroy -auto-approve
```

---

[Back to main README](../README.md) | [Next: Phase 2 — Lift and Shift](../phase-2-lift-and-shift/README.md)
