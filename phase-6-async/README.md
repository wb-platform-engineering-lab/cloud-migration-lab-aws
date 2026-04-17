# Phase 6 — Decouple with SQS and SNS

> **AWS services introduced:** SQS, SNS, EventBridge | **Daily cost:** ~$6.40/day (SQS/SNS in free tier)

## Objective

Stop doing everything synchronously in the order request. Write the order to the database, publish an event, and return. Email, inventory, and warehouse notifications happen asynchronously and retry automatically on failure.

## AWS services

| Service | Why we need it |
|---|---|
| **SQS** | Message queue — decouples order creation from downstream processing |
| **SNS** | Pub/sub — fan out a single event to multiple consumer queues |
| **EventBridge** | Event bus with routing rules for AWS service events |

## Terraform structure

```
terraform/
├── sns.tf           # SNS topic: orderflow-order-events
├── sqs.tf           # SQS queues + DLQs (email, inventory, warehouse)
├── subscriptions.tf # SNS → SQS subscriptions
└── variables.tf
```

## Architecture

```
Order API → write to RDS → publish to SNS (OrderCreated)
                               ├── SQS: order-email     → Lambda: send confirmation
                               ├── SQS: order-inventory → ECS: inventory service
                               └── SQS: order-warehouse → ECS: warehouse notifier

Each queue has a DLQ — messages that fail 3× land there for inspection.
```

## Key concept: at-least-once delivery

SQS guarantees delivery **at least once** — not exactly once. Consumers must be **idempotent**: processing the same message twice must produce the same result as processing it once.

- Email: check if the email was already sent before sending
- Inventory: use a database transaction with a unique order ID constraint

## Challenges

1. Create SNS topic `orderflow-order-events`
2. Create three SQS queues subscribing to SNS. Add a DLQ to each (max receives: 3).
3. Refactor the order endpoint: write to DB → publish to SNS → return 201. Remove all synchronous downstream calls.
4. Write a Lambda triggered by the `order-email` queue. Send confirmation via SES.
5. Simulate consumer failure: stop the inventory service while placing orders. Confirm orders still succeed and messages queue. Restart and watch the queue drain.
6. Set visibility timeout larger than consumer processing time. Understand what happens when it is too short.

## Outcome

Order response time drops by the time previously spent on email + inventory + warehouse. Downstream failures no longer fail the order. DLQs give visibility into what failed and why.

## Cost breakdown

| Resource | $/day |
|---|---|
| Phase 5 baseline | ~$5.80 |
| SQS + SNS | ~$0 (within free tier) |
| **Total** | **~$5.80** |

```bash
cd terraform && terraform destroy -auto-approve
```

---

[Back to main README](../README.md)
