# Phase 3 — Containerize and ECS

> **AWS services introduced:** ECS Fargate, ECR | **Daily cost:** ~$6.30/day

## Objective

Replace the EC2 Auto Scaling Group with ECS Fargate. Deploys go from slow, error-prone AMI refreshes to a 2-minute rolling replacement with zero downtime.

## AWS services

| Service | Why we need it |
|---|---|
| **ECR** | Docker image registry integrated with IAM |
| **ECS Fargate** | Runs containers without managing EC2 instances |
| **ECS Service** | Maintains desired task count, health checks, rolling deploys |
| **ECS Task Definition** | Specifies image, CPU, memory, environment, and IAM role |

## Terraform structure

```
terraform/
├── ecr.tf           # ECR repository
├── ecs_cluster.tf   # ECS cluster
├── ecs_task.tf      # Task definition (image, CPU, memory, secrets)
├── ecs_service.tf   # Service (desired count, ALB wiring, rolling deploy)
├── iam.tf           # Task execution role + task role
└── variables.tf
```

## Architecture

```
ALB → ECS Service (Fargate, desired: 2)
         ├── Task — orderflow:sha1234 (0.5 vCPU / 1 GB)
         └── Task — orderflow:sha1234 (0.5 vCPU / 1 GB)
                  ├── RDS PostgreSQL
                  └── ElastiCache Redis
```

## Challenges

1. Create an ECR repository for `orderflow`. Push the Phase 0 image.
2. Write an ECS Task Definition. Grant it an IAM task role with permission to read from Secrets Manager.
3. Update the app to read `DB_PASSWORD` from Secrets Manager at startup.
4. Create an ECS Service (desired count: 2) wired to the ALB target group.
5. Deploy a new image version — observe the rolling replace: new tasks start, health checks pass, old tasks drain.
6. Scale to 0 tasks after hours using ECS scheduled scaling (cost control).

## Key concept: IAM task roles

Unlike EC2 instance profiles (where all processes share one role), ECS task roles are per-container. The OrderFlow container reads from Secrets Manager. A future reporting container writes to S3. Neither can do what the other can.

## Outcome

OrderFlow runs on ECS Fargate. No EC2 instances to manage. Deploys take 2–3 minutes with zero downtime. The EC2 Auto Scaling Group from Phase 2 is decommissioned.

## Cost breakdown

| Resource | $/day |
|---|---|
| 2× NAT Gateway | $2.16 |
| ECS Fargate (2× 0.5 vCPU / 1 GB) | $1.19 |
| RDS + ElastiCache + ALB | $2.29 |
| ECR storage | ~$0.05 |
| **Total** | **~$5.69** |

```bash
cd terraform && terraform destroy -auto-approve
```

---

[Back to main README](../README.md)
