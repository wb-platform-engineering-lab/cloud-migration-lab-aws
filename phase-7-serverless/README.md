# Phase 7 — Serverless for the Right Problems

> **AWS services introduced:** Lambda, API Gateway, EventBridge Scheduler, Step Functions | **Daily cost:** ~$6.40/day (Lambda in free tier)

## Objective

Extract CPU-intensive and scheduled jobs from the monolith and run them as Lambda functions. The container CPU profile becomes flat. The event loop is no longer blocked by report generation.

## AWS services

| Service | Why we need it |
|---|---|
| **Lambda** | Runs code in response to events without managing servers |
| **API Gateway** | Routes HTTP requests to Lambda functions |
| **EventBridge Scheduler** | Replaces cron jobs that ran inside the monolith |
| **Step Functions** | Orchestrates multi-step workflows with retries and branching |

## Terraform structure

```
terraform/
├── lambda_report.tf      # Daily report generator
├── lambda_email.tf       # Order confirmation email (from Phase 6 SQS)
├── lambda_resize.tf      # Product image thumbnail generator
├── lambda_inventory.tf   # Low-stock alert sender
├── eventbridge.tf        # Scheduler rules (cron)
└── variables.tf
```

## What moves to Lambda

| From | Function | Trigger |
|---|---|---|
| Monolith cron | Daily PDF report → S3 → SES | EventBridge Scheduler `cron(0 6 * * ? *)` |
| Monolith email service | Order confirmation email | SQS (from Phase 6) |
| New | Product image resize (300×300) | S3 event on `uploads/` prefix |
| New | Low-stock SNS alert | SQS inventory queue |

## When Lambda is the wrong answer

Lambda has cold starts, a 15-minute maximum duration, and a stateless execution model. The order API stays on ECS. Use Lambda for event-driven, short-duration, or scheduled workloads.

## Challenges

1. Extract the daily report to Lambda. Trigger with EventBridge Scheduler at `cron(0 6 * * ? *)`. Write PDF to S3, send S3 URL via SES.
2. Confirm the report fits in 15 minutes. If not, refactor into a Step Functions workflow that parallelises the work.
3. Add an S3 event notification: `uploads/` prefix → Lambda that resizes to 300×300 and writes to `thumbnails/`.
4. Write a Lambda for low-stock alerts triggered from the inventory SQS queue.
5. Delete the cron code from the monolith. Measure container CPU reduction during report generation time.

## Lambda pricing example

Report generator at 512 MB RAM, 8 minutes:
`0.5 GB × 480 s = 240 GB-seconds = $0.004/run`
Running daily: **$0.12/month** vs $15+/month on a dedicated EC2 instance.

## Outcome

The monolith no longer runs cron jobs or non-request-path logic. Event-driven functions are independently deployable. Container CPU profiles are flat during peak hours.

## Cost breakdown

| Resource | $/day |
|---|---|
| Phase 6 baseline | ~$5.80 |
| Lambda + EventBridge | ~$0 (within free tier) |
| **Total** | **~$5.80** |

```bash
cd terraform && terraform destroy -auto-approve
```

---

[Back to main README](../README.md)
