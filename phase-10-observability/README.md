# Phase 10 — Observability

> **AWS services introduced:** CloudWatch, X-Ray, Managed Prometheus, Managed Grafana | **Daily cost:** ~$10.30/day

## Objective

When a customer reports a missing order confirmation email, you should be able to trace the request across Lambda, ECS/EKS, and RDS in under 2 minutes — not grep five separate log files hoping to find a correlation.

## AWS services

| Service | Why we need it |
|---|---|
| **CloudWatch Logs** | Centralized logs from all containers, Lambda, and AWS services |
| **CloudWatch Metrics** | Built-in ALB, ECS, RDS, SQS metrics |
| **CloudWatch Alarms** | Page on-call when error rate or queue depth exceeds threshold |
| **X-Ray** | Distributed tracing — follow a request across every service boundary |
| **Managed Grafana** | Unified dashboards across CloudWatch, X-Ray, and Prometheus |

## Terraform structure

```
terraform/
├── cloudwatch.tf    # Log groups, dashboards, alarms
├── xray.tf          # X-Ray sampling rules
├── prometheus.tf    # Amazon Managed Prometheus workspace
├── grafana.tf       # Amazon Managed Grafana workspace + data sources
└── variables.tf
```

## Observability stack

```
Metrics  → CloudWatch (AWS services) + Prometheus (EKS) → Grafana
Logs     → CloudWatch Logs (Lambda, ECS) + Fluent Bit (EKS) → Logs Insights
Traces   → X-Ray SDK → X-Ray console → correlate with logs via trace ID
Alerts   → CloudWatch Alarms → SNS → email / Slack / PagerDuty
```

## Challenges

1. Install the X-Ray SDK in the OrderFlow Node.js app. Instrument Express middleware and outbound HTTP calls. Confirm traces appear in the X-Ray console.
2. Enable X-Ray on Lambda functions (`TracingConfig: Active`).
3. Create a CloudWatch dashboard: ALB 5xx rate, ECS CPU/memory, RDS connections, SQS DLQ depth, Lambda error rate.
4. Create an alarm: if `order-email-dlq` message count > 0 for 5 minutes → SNS → email on-call. A message in the DLQ means a confirmation email failed 3 times.
5. Install `kube-prometheus-stack` on EKS. Configure remote write to Managed Prometheus. Connect Managed Grafana to both CloudWatch and Managed Prometheus.
6. Find the latency bottleneck: use X-Ray to identify which downstream call adds the most latency to `POST /orders`. Optimise it.

## Outcome

A single Grafana dashboard shows the health of the entire platform. Any failing request can be traced end-to-end. Alerts page on-call for DLQ depth, 5xx spikes, and RDS connection exhaustion.

## Cost breakdown

| Resource | $/day |
|---|---|
| Phase 9 baseline | ~$8.91 |
| CloudWatch Logs (~0.5 GB/day) | ~$0.30 |
| Managed Grafana (1 active user) | ~$0.30 |
| Managed Prometheus | ~$0.10 |
| **Total** | **~$9.61** |

```bash
cd terraform && terraform destroy -auto-approve
```

---

[Back to main README](../README.md)
