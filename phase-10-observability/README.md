# Phase 10 — Observability

> **AWS services introduced:** CloudWatch, X-Ray, Managed Prometheus, Managed Grafana | **Daily cost:** ~$10.30/day

---

## AWS services introduced

| Service | What it does | Why we need it |
|---|---|---|
| **CloudWatch Logs** | Centralized log storage | All containers, Lambda functions, and AWS services log here |
| **CloudWatch Metrics** | AWS service metrics | ALB request counts, ECS CPU, RDS connections — all built-in |
| **CloudWatch Alarms** | Threshold-based alerts | Page on-call when error rate exceeds threshold |
| **X-Ray** | Distributed tracing | Trace a single request across Lambda → ECS → RDS |
| **Managed Grafana** | Dashboards | Unified view across CloudWatch, X-Ray, and custom metrics |

## The problem

OrderFlow is now distributed across ECS, EKS, Lambda, RDS, SQS, and CloudFront. A customer reports that their order confirmation email never arrived. Where do you start looking?

Without distributed tracing, you grep log files from five services hoping to find a correlation. With X-Ray, you open the trace for that request and see exactly which service failed, at what latency, with what error.

## Observability pillars in this architecture

```
Metrics   → CloudWatch (AWS services) + Prometheus (EKS workloads) → Grafana
Logs      → CloudWatch Logs (Lambda, ECS) + Fluent Bit (EKS) → CloudWatch Logs Insights
Traces    → X-Ray SDK in app code → X-Ray console → correlate with logs
Alerts    → CloudWatch Alarms → SNS → PagerDuty / Slack
```

## Challenges

1. Install the AWS X-Ray SDK in the OrderFlow Node.js app. Instrument the Express middleware and outbound HTTP calls. Confirm traces appear in the X-Ray console.
2. Add X-Ray to the Lambda functions — the Lambda runtime supports X-Ray with a single `TracingConfig: Active` flag.
3. Create a CloudWatch dashboard with: ALB 5xx rate, ECS CPU/memory, RDS connections, SQS queue depth (DLQ size is your error rate proxy), Lambda duration and error rate.
4. Create a CloudWatch Alarm: if `orderflow-order-email-dlq` message count > 0 for 5 minutes, send to an SNS topic that emails the on-call. A message in the DLQ means a confirmation email failed 3 times.
5. Install kube-prometheus-stack on EKS. Configure remote write to Amazon Managed Prometheus. Connect Managed Grafana to both CloudWatch and Managed Prometheus data sources so all metrics are in one dashboard.
6. Find the latency bottleneck: use X-Ray to identify which downstream call adds the most latency to `POST /orders`. Optimize it.

## Outcome

A single Grafana dashboard shows the health of the entire OrderFlow platform. An X-Ray trace can be pulled for any failing request. Alerts page on-call for DLQ depth, 5xx spikes, and RDS connection exhaustion.

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

[Back to main README](../README.md) | [Next: Phase 11 — Security Hardening](../phase-11-security/README.md)
