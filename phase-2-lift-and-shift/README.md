# Phase 2 — Lift and Shift

> **AWS services introduced:** EC2, RDS, ElastiCache, ALB, Route 53, ACM | **Daily cost:** ~$6.10/day

## Objective

Move the OrderFlow monolith to AWS with minimum code changes. This is not the end state — it is a stable platform from which to run every subsequent phase.

## AWS services

| Service | Why we need it |
|---|---|
| **EC2** | Runs the monolith — same as the VPS, but managed by AWS |
| **RDS PostgreSQL Multi-AZ** | Managed database with automatic failover |
| **ElastiCache Redis** | Shared session store — fixes the session bug from Phase 0 |
| **ALB** | Distributes traffic across multiple app instances |
| **Route 53** | DNS — maps your domain to the ALB |
| **ACM** | Free TLS certificates, auto-renewed |

## Terraform structure

```
terraform/
├── ec2.tf           # Launch template + Auto Scaling Group
├── rds.tf           # RDS PostgreSQL Multi-AZ
├── elasticache.tf   # Redis cluster
├── alb.tf           # Application Load Balancer + target groups
├── route53.tf       # DNS record pointing to ALB
├── acm.tf           # TLS certificate
└── variables.tf
```

## Architecture

```
Route 53 → ALB (public subnet)
              ├── EC2 — Monolith (private subnet AZ-a)
              └── EC2 — Monolith (private subnet AZ-b)
                        ├── RDS PostgreSQL Multi-AZ
                        └── ElastiCache Redis (shared sessions)
```

## Challenges

1. Provision RDS PostgreSQL in the private subnets. Enable Multi-AZ. Store the password in Secrets Manager (not in Terraform state).
2. Provision ElastiCache Redis. Update the monolith session store to point at it.
3. Create a launch template and Auto Scaling Group (min: 1, max: 3) in the private subnets.
4. Create an ALB in the public subnets with a target group and health checks on `GET /health`.
5. Request an ACM certificate. Add an HTTPS listener. Redirect HTTP → HTTPS.
6. Re-run the session test from Phase 0 — confirm sessions persist across instances.
7. Simulate an RDS failover (`aws rds reboot-db-instance --force-failover`) — measure downtime.

## Outcome

OrderFlow runs on AWS, survives a server failure, and the session bug from Phase 0 is resolved. Monolith code is unchanged — only its environment changed.

## Cost breakdown

| Resource | $/day |
|---|---|
| 2× NAT Gateway (from Phase 1) | $2.16 |
| 2× EC2 t3.small | $1.00 |
| RDS PostgreSQL db.t3.small Multi-AZ | $1.63 |
| ElastiCache cache.t3.micro | $0.41 |
| ALB | $0.25 |
| Route 53 + ACM | ~$0.05 |
| **Total** | **~$5.50** |

```bash
cd terraform && terraform destroy -auto-approve
```

---

[Back to main README](../README.md)
