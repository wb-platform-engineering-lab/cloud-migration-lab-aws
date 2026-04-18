# Phase 7 — Serverless for the Right Problems

> **AWS services introduced:** Lambda, API Gateway, EventBridge Scheduler, Step Functions | **Daily cost:** ~$6.40/day (Lambda within free tier)

---

## AWS services introduced

| Service | What it does | Why we need it |
|---|---|---|
| **Lambda** | Functions as a service | Runs code in response to events without managing servers |
| **API Gateway** | Managed HTTP/WebSocket API layer | Routes HTTP requests to Lambda functions or other AWS services |
| **EventBridge Scheduler** | Cron-like scheduled invocations | Replaces cron jobs that ran inside the monolith |
| **Step Functions** | Orchestrated workflows | Coordinates multi-step processes with retries and branching |

## The problem

The daily sales report in OrderFlow runs as a cron job inside the Node.js process. It generates a PDF, emails it to finance, and writes a summary to PostgreSQL. It runs at 6 AM and takes 8 minutes. During those 8 minutes, Node's event loop is partially blocked and API latency spikes.

Lambda is not the answer for everything. But it is the right answer for:
- **Event-driven functions** that run for seconds in response to a trigger (send email, process upload)
- **Scheduled jobs** that run on a timer (daily reports, cleanup tasks)
- **Glue code** that connects AWS services without maintaining a server

## When Lambda is the wrong answer

Lambda has cold starts, a 15-minute maximum duration, and an execution model that is fundamentally different from a long-running server. Do not put your order API on Lambda. Keep it on ECS where it belongs. Use Lambda for what it was designed for.

## What moves to Lambda in this phase

| Current location | What it does | Lambda trigger |
|---|---|---|
| Monolith cron | Generate daily PDF report, email to finance | EventBridge Scheduler (cron) |
| Monolith email service | Send order confirmation emails | SQS (from Phase 6) |
| New | Resize uploaded product images on upload | S3 event notification |
| New | Send low-stock alerts when inventory drops | EventBridge rule on DynamoDB stream |

## Challenges

1. Extract the daily report generator into a Lambda function. Trigger it with EventBridge Scheduler at `cron(0 6 * * ? *)`. Write the PDF to S3 and send the S3 URL via SES.
2. The report takes 8 minutes — but Lambda has a 15-minute limit. Measure actual duration and confirm it fits. If it does not, refactor it into a Step Functions workflow that splits the work.
3. Add an S3 event notification: when a product image is uploaded to the `uploads/` prefix, invoke a Lambda that resizes it to 300×300 and writes to `thumbnails/`.
4. Write a Lambda to send low-stock SNS alerts when an inventory item drops below 10 units. Trigger it from the inventory SQS queue.
5. Delete the cron code from the monolith. Measure the reduction in container CPU during report generation time.

## AWS concept: Lambda pricing model

Lambda charges per request ($0.0000002/request) and per GB-second of compute time ($0.0000166667/GB-second). The report generator at 512 MB RAM running for 8 minutes = 0.5 GB × 480 seconds = 240 GB-seconds = $0.004 per run. Running daily: $0.12/month. The same workload on a dedicated EC2 instance would cost $15+/month. Lambda's economics are compelling for intermittent workloads.

## Outcome

The monolith no longer runs any cron jobs or non-request-path logic. The event-driven email and report functions are independently deployable. Container CPU profiles are flat during peak hours.

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

[Back to main README](../README.md) | [Next: Phase 8 — Auth with Cognito](../phase-8-cognito/README.md)
