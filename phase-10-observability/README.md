# Phase 10 — Observability

> **AWS services introduced:** CloudWatch, X-Ray, Managed Prometheus, Managed Grafana | **Daily cost:** ~$9.61/day

---

## AWS services introduced

| Service | What it does | Why we need it |
|---|---|---|
| **CloudWatch Logs** | Centralized log storage | All containers, Lambda functions, and AWS services log here |
| **CloudWatch Metrics** | AWS service metrics | ALB request counts, ECS CPU, RDS connections — all built-in |
| **CloudWatch Alarms** | Threshold-based alerts | Page on-call when error rate exceeds threshold |
| **X-Ray** | Distributed tracing | Trace a single request across Lambda → ECS → RDS |
| **Managed Grafana** | Dashboards | Unified view across CloudWatch, X-Ray, and custom metrics |
| **Managed Prometheus** | EKS workload metrics | Pull metrics from pods; remote-write to AWS-managed storage |
| **Fluent Bit** | Log forwarding from EKS | Ships pod logs to CloudWatch Logs without changing app code |

## The problem

OrderFlow is now distributed across EKS, Lambda, RDS, SQS, and CloudFront. A customer reports their order confirmation email never arrived. Where do you start?

Without distributed tracing you grep log files across five services hoping to find a correlation. With X-Ray you open the trace for that specific request and see exactly which service failed, at what latency, and with what error — in seconds.

## Observability pillars

```
Metrics   → CloudWatch (AWS services) + Prometheus (EKS pods) → Grafana
Logs      → CloudWatch Logs (Lambda, ECS) + Fluent Bit (EKS)  → Logs Insights
Traces    → X-Ray SDK in app code → X-Ray console
Alerts    → CloudWatch Alarms → SNS → email / Slack
```

---

## Challenge 1 — Instrument the Node.js app with X-Ray

**Goal:** Add X-Ray tracing to the OrderFlow Express app so every inbound HTTP request and outbound database call generates a trace segment.

### Step 1: Install the X-Ray SDK

```bash
cd orderflow
npm install aws-xray-sdk-core aws-xray-sdk-express
```

### Step 2: Instrument `src/app.js`

Add X-Ray middleware **before** all routes:

```js
// src/app.js
const AWSXRay = require('aws-xray-sdk-core');
const XRayExpress = require('aws-xray-sdk-express');

// Instrument the AWS SDK — auto-traces Secrets Manager, SNS, S3 calls
const AWS = AWSXRay.captureAWS(require('aws-sdk'));

const app = require('express')();

// X-Ray: open a segment at the start of every request
app.use(XRayExpress.openSegment('orderflow-api'));

// ... all other middleware and routes here ...

// X-Ray: close the segment at the end of every request
app.use(XRayExpress.closeSegment());
```

### Step 3: Instrument outbound PostgreSQL calls

Sequelize uses a connection pool. Wrap each query in an X-Ray subsegment:

```js
// src/services/database.js
const AWSXRay = require('aws-xray-sdk-core');

// Wrap the critical query path
async function findOrderById(id) {
  const segment = AWSXRay.getSegment();
  const subsegment = segment.addNewSubsegment('postgres.findOrder');

  try {
    const order = await Order.findByPk(id);
    subsegment.close();
    return order;
  } catch (err) {
    subsegment.addError(err);
    subsegment.close();
    throw err;
  }
}
```

### Step 4: Enable X-Ray in the ECS task definition / EKS deployment

X-Ray requires a daemon running alongside the app to receive UDP trace data and batch-send it to the X-Ray service. Add it as a sidecar.

**ECS task definition** — add to the `containerDefinitions` array in your task definition:

```json
{
  "name": "xray-daemon",
  "image": "amazon/aws-xray-daemon",
  "essential": false,
  "portMappings": [
    { "containerPort": 2000, "protocol": "udp" }
  ],
  "cpu": 32,
  "memoryReservation": 256
}
```

**EKS** — add a sidecar to `phase-9-eks/helm/orderflow/templates/deployment.yaml`:

```yaml
      containers:
        - name: api
          # ... existing container spec ...

        - name: xray-daemon
          image: amazon/aws-xray-daemon
          ports:
            - containerPort: 2000
              protocol: UDP
          resources:
            requests:
              cpu: 32m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
```

The X-Ray SDK sends trace data to `localhost:2000` (UDP) by default. The daemon batches and forwards to the X-Ray API over HTTPS.

### Step 5: Grant X-Ray permissions via IRSA

The daemon needs to call `xray:PutTraceSegments` and `xray:PutTelemetryRecords`. Add to the IRSA role policy in `phase-9-eks/terraform/irsa_orders.tf`:

```hcl
statement {
  effect  = "Allow"
  actions = [
    "xray:PutTraceSegments",
    "xray:PutTelemetryRecords",
    "xray:GetSamplingRules",
    "xray:GetSamplingTargets",
  ]
  resources = ["*"]
}
```

Apply and redeploy:

```bash
terraform apply -auto-approve

helm upgrade orderflow phase-9-eks/helm/orderflow \
  --namespace orderflow \
  --reuse-values
```

### Step 6: Generate traces and verify in the console

```bash
ALB_URL=$(kubectl get ingress orderflow -n orderflow \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Generate 20 requests
for i in $(seq 1 20); do
  curl -s "https://${ALB_URL}/health" > /dev/null
  curl -s -X POST "https://${ALB_URL}/orders" \
    -H "Content-Type: application/json" \
    -d '{"productId":1,"quantity":1}' > /dev/null
done
```

Open the X-Ray console → **Traces**. You should see:

```
Service map:
  orderflow-api → postgres (Subsegment)
               → secretsmanager (AWS SDK subsegment)
               → sns (AWS SDK subsegment)

Trace summary:
  POST /orders  avg 45ms  p99 120ms  0 errors
  GET /health   avg 3ms   p99 8ms    0 errors
```

---

## Challenge 2 — Enable X-Ray for Lambda functions

**Goal:** Add active X-Ray tracing to the daily report and email Lambda functions with a single Terraform flag.

### Step 1: Update `phase-7-serverless/terraform/lambda.tf`

Add `tracing_config` to both Lambda functions:

```hcl
resource "aws_lambda_function" "daily_report" {
  # ... existing config ...

  tracing_config {
    mode = "Active"  # Samples 5% of requests by default; can be tuned in X-Ray sampling rules
  }
}

resource "aws_lambda_function" "send_email" {
  # ... existing config ...

  tracing_config {
    mode = "Active"
  }
}
```

The Lambda runtime automatically starts an X-Ray segment for each invocation when `Active` mode is set — no SDK changes needed for the root segment. To trace outbound calls (AWS SDK, HTTP), install and use the SDK as in Challenge 1.

### Step 2: Apply

```bash
cd phase-7-serverless/terraform
terraform apply -auto-approve
```

### Step 3: Trigger the Lambda and inspect the trace

```bash
# Manually invoke the daily report Lambda
aws lambda invoke \
  --function-name orderflow-daily-report \
  --payload '{}' \
  --log-type Tail \
  response.json \
  --query 'LogResult' \
  --output text | base64 -d
```

Then in the X-Ray console → **Traces** → filter by `annotation.aws:lambda.function_name = "orderflow-daily-report"`.

Expected trace segments:

```
Lambda (orderflow-daily-report)
  └── Initialization  ~200ms
  └── Invocation      ~1400ms
        └── secretsmanager.GetSecretValue  ~40ms
        └── postgres.queryDailySummary     ~320ms
        └── s3.PutObject (report PDF)      ~180ms
        └── ses.SendEmail                  ~250ms
```

### Step 4: Verify the end-to-end trace from API to Lambda

Place an order through the API — it publishes to SNS → SQS → Lambda. In the X-Ray Service Map you should see:

```
orderflow-api → SNS → SQS → orderflow-send-email → SES
```

This is the value of distributed tracing: one trace ID threads across all services.

---

## Challenge 3 — Build a CloudWatch dashboard

**Goal:** Create a single dashboard that shows the health of the entire OrderFlow platform at a glance.

### Step 1: Create `phase-10-observability/terraform/dashboard.tf`

```hcl
locals {
  dashboard_body = jsonencode({
    widgets = [
      # ── ALB: request rate and error rate ─────────────────────────────
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "ALB — Request Rate & 5xx Errors"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "RequestCount",
              "LoadBalancer", data.aws_lb.main.arn_suffix,
              { stat = "Sum", period = 60, label = "Total Requests" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count",
              "LoadBalancer", data.aws_lb.main.arn_suffix,
              { stat = "Sum", period = 60, label = "5xx Errors", color = "#d62728" }],
          ]
          view    = "timeSeries"
          yAxis   = { left = { min = 0 } }
        }
      },
      # ── EKS nodes: CPU and memory ────────────────────────────────────
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "EKS Nodes — CPU & Memory"
          region = var.aws_region
          metrics = [
            ["ContainerInsights", "node_cpu_utilization",
              "ClusterName", var.eks_cluster_name,
              { stat = "Average", period = 60, label = "CPU %" }],
            ["ContainerInsights", "node_memory_utilization",
              "ClusterName", var.eks_cluster_name,
              { stat = "Average", period = 60, label = "Memory %", yAxis = "right" }],
          ]
          view = "timeSeries"
        }
      },
      # ── RDS: connections and latency ─────────────────────────────────
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "RDS — Connections & Query Latency"
          region = var.aws_region
          metrics = [
            ["AWS/RDS", "DatabaseConnections",
              "DBInstanceIdentifier", "orderflow-postgres",
              { stat = "Average", period = 60, label = "Active Connections" }],
            ["AWS/RDS", "ReadLatency",
              "DBInstanceIdentifier", "orderflow-postgres",
              { stat = "Average", period = 60, label = "Read Latency (s)", yAxis = "right" }],
            ["AWS/RDS", "WriteLatency",
              "DBInstanceIdentifier", "orderflow-postgres",
              { stat = "Average", period = 60, label = "Write Latency (s)", yAxis = "right" }],
          ]
          view = "timeSeries"
        }
      },
      # ── SQS DLQs: dead letters are failed processing ──────────────────
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "SQS Dead-Letter Queues — Message Count"
          region = var.aws_region
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible",
              "QueueName", "orderflow-order-email-dlq",
              { stat = "Maximum", period = 300, label = "Email DLQ", color = "#d62728" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible",
              "QueueName", "orderflow-order-inventory-dlq",
              { stat = "Maximum", period = 300, label = "Inventory DLQ", color = "#ff7f0e" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible",
              "QueueName", "orderflow-order-warehouse-dlq",
              { stat = "Maximum", period = 300, label = "Warehouse DLQ", color = "#9467bd" }],
          ]
          view = "timeSeries"
          yAxis = { left = { min = 0 } }
          annotations = {
            horizontal = [{ value = 1, label = "Alert threshold", color = "#d62728" }]
          }
        }
      },
      # ── Lambda: duration and errors ───────────────────────────────────
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "Lambda — Duration & Error Rate"
          region = var.aws_region
          metrics = [
            ["AWS/Lambda", "Duration",
              "FunctionName", "orderflow-send-email",
              { stat = "p99", period = 60, label = "send-email p99" }],
            ["AWS/Lambda", "Duration",
              "FunctionName", "orderflow-daily-report",
              { stat = "p99", period = 60, label = "daily-report p99" }],
            ["AWS/Lambda", "Errors",
              "FunctionName", "orderflow-send-email",
              { stat = "Sum", period = 60, label = "send-email errors", yAxis = "right", color = "#d62728" }],
          ]
          view = "timeSeries"
        }
      },
      # ── ElastiCache: cache hits ───────────────────────────────────────
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "ElastiCache Redis — Cache Hit Rate"
          region = var.aws_region
          metrics = [
            ["AWS/ElastiCache", "CacheHits",
              "CacheClusterId", "orderflow-redis",
              { stat = "Sum", period = 60, label = "Hits" }],
            ["AWS/ElastiCache", "CacheMisses",
              "CacheClusterId", "orderflow-redis",
              { stat = "Sum", period = 60, label = "Misses", color = "#ff7f0e" }],
          ]
          view = "timeSeries"
        }
      },
    ]
  })
}

data "aws_lb" "main" {
  tags = { Name = "${var.project}-alb" }
}

resource "aws_cloudwatch_dashboard" "orderflow" {
  dashboard_name = var.project
  dashboard_body = local.dashboard_body
}
```

### Step 2: Create `phase-10-observability/terraform/variables.tf`

```hcl
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "orderflow"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "eks_cluster_name" {
  type    = string
  default = "orderflow"
}

variable "alert_email" {
  description = "Email address to receive CloudWatch alarm notifications"
  type        = string
}
```

### Step 3: Apply and open the dashboard

```bash
cd phase-10-observability/terraform
terraform init
terraform apply -auto-approve
```

Open the dashboard:

```bash
echo "https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home#dashboards:name=orderflow"
```

---

## Challenge 4 — CloudWatch Alarms and SNS notifications

**Goal:** Page on-call when a dead-letter queue has messages (failed processing) or when the ALB 5xx rate spikes.

### Step 1: Create the SNS topic for alerts

Add to `phase-10-observability/terraform/alarms.tf`:

```hcl
# SNS topic for alarm notifications
resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
  tags = { Name = "${var.project}-alerts" }
}

resource "aws_sns_topic_subscription" "alert_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
```

### Step 2: Create alarms

Append to `alarms.tf`:

```hcl
# ── Alarm: any message in the email DLQ ─────────────────────────────────────
# A DLQ message = email delivery failed 3 times = customer never received confirmation
resource "aws_cloudwatch_metric_alarm" "email_dlq" {
  alarm_name          = "${var.project}-email-dlq-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300   # 5 minutes
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Email DLQ has messages — order confirmation emails are failing"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = "orderflow-order-email-dlq"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ── Alarm: ALB 5xx error rate > 1% ──────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "alb_5xx_rate" {
  alarm_name          = "${var.project}-alb-5xx-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 1

  # Use a metric math expression: 5xx / total * 100 = error rate %
  metric_query {
    id          = "error_rate"
    expression  = "m2/m1*100"
    label       = "5xx Error Rate %"
    return_data = true
  }

  metric_query {
    id = "m1"
    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = data.aws_lb.main.arn_suffix
      }
    }
  }

  metric_query {
    id = "m2"
    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = data.aws_lb.main.arn_suffix
      }
    }
  }

  alarm_description  = "ALB 5xx error rate exceeded 1% for 2 consecutive minutes"
  treat_missing_data = "notBreaching"
  alarm_actions      = [aws_sns_topic.alerts.arn]
}

# ── Alarm: RDS connection count approaching pool limit ────────────────────────
resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.project}-rds-connections-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  # db.t3.micro max_connections ≈ 34. Alert at 80%
  threshold           = 27
  alarm_description   = "RDS connection count above 80% of max — risk of connection exhaustion"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = "${var.project}-postgres"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}
```

### Step 3: Apply and confirm subscription

```bash
terraform apply -auto-approve
```

You will receive a **subscription confirmation email** — click the link before alarms can notify you.

### Step 4: Test the DLQ alarm

Send a message directly to the dead-letter queue to trigger the alarm:

```bash
DLQ_URL=$(aws sqs get-queue-url \
  --queue-name orderflow-order-email-dlq \
  --query QueueUrl --output text)

aws sqs send-message \
  --queue-url "$DLQ_URL" \
  --message-body '{"test":"alarm trigger"}'
```

Wait 5 minutes. You should receive an email notification:

```
Subject: ALARM: "orderflow-email-dlq-depth" in US East (N. Virginia)

State:     ALARM
Reason:    Threshold Crossed: 1 datapoint [1.0 (timestamp)] was greater than
           the threshold (0.0).
```

Clean up the test message:

```bash
RECEIPT=$(aws sqs receive-message \
  --queue-url "$DLQ_URL" \
  --query 'Messages[0].ReceiptHandle' --output text)

aws sqs delete-message \
  --queue-url "$DLQ_URL" \
  --receipt-handle "$RECEIPT"
```

---

## Challenge 5 — EKS metrics: Prometheus and Grafana

**Goal:** Ship pod-level metrics from EKS to Amazon Managed Prometheus, then visualise them in Amazon Managed Grafana alongside CloudWatch metrics.

### Step 1: Create the Managed Prometheus workspace

Add to `phase-10-observability/terraform/prometheus.tf`:

```hcl
resource "aws_prometheus_workspace" "orderflow" {
  alias = var.project
  tags  = { Name = var.project }
}

output "prometheus_endpoint" {
  value = aws_prometheus_workspace.orderflow.prometheus_endpoint
}
```

Apply:

```bash
terraform apply -auto-approve
PROM_ENDPOINT=$(terraform output -raw prometheus_endpoint)
```

### Step 2: Install kube-prometheus-stack with remote write to AMP

The `kube-prometheus-stack` Helm chart installs Prometheus, Alertmanager, and Grafana in the cluster. We use it only for the Prometheus scraping engine — dashboards come from Managed Grafana.

Create the IRSA role for Prometheus remote write:

```hcl
# In phase-9-eks/terraform/irsa_prometheus.tf
locals {
  oidc_host = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}

resource "aws_iam_role" "prometheus" {
  name = "${var.project}-prometheus"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRoleWithWebIdentity"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Condition = {
        StringEquals = {
          "${local.oidc_host}:sub" = "system:serviceaccount:monitoring:prometheus-server"
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "prometheus_amp" {
  role       = aws_iam_role.prometheus.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess"
}

output "prometheus_role_arn" {
  value = aws_iam_role.prometheus.arn
}
```

Apply then install:

```bash
cd phase-9-eks/terraform
terraform apply -auto-approve
PROM_ROLE=$(terraform output -raw prometheus_role_arn)

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${PROM_ROLE}" \
  --set prometheus.prometheusSpec.remoteWrite[0].url="${PROM_ENDPOINT}api/v1/remote_write" \
  --set prometheus.prometheusSpec.remoteWrite[0].sigv4.region="${AWS_REGION}" \
  --set prometheus.prometheusSpec.remoteWrite[0].sigv4.roleArn="${PROM_ROLE}" \
  --set grafana.enabled=false \
  --set alertmanager.enabled=false \
  --wait
```

### Step 3: Verify metrics are flowing to AMP

```bash
# Query AMP directly to confirm remote write is working
awscurl --service="aps" --region="${AWS_REGION}" \
  "${PROM_ENDPOINT}api/v1/query?query=up" | jq '.data.result | length'
```

Expected: a number > 0 (one `up` metric per scrape target).

### Step 4: Create the Managed Grafana workspace

Add to `phase-10-observability/terraform/grafana.tf`:

```hcl
resource "aws_grafana_workspace" "orderflow" {
  name                     = var.project
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"

  data_sources = [
    "CLOUDWATCH",
    "PROMETHEUS",
    "XRAY",
  ]

  role_arn = aws_iam_role.grafana.arn

  tags = { Name = var.project }
}

resource "aws_iam_role" "grafana" {
  name = "${var.project}-grafana"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "grafana.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "grafana_cloudwatch" {
  role       = aws_iam_role.grafana.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "grafana_xray" {
  role       = aws_iam_role.grafana.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXrayReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "grafana_prometheus" {
  role       = aws_iam_role.grafana.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusQueryAccess"
}

output "grafana_endpoint" {
  value = "https://${aws_grafana_workspace.orderflow.endpoint}"
}
```

Apply:

```bash
terraform apply -auto-approve
echo "Grafana: $(terraform output -raw grafana_endpoint)"
```

### Step 5: Connect data sources in Grafana

Open the Grafana URL from the output. Sign in with your SSO user, then:

1. **CloudWatch**: Settings → Data Sources → Add → CloudWatch → select `us-east-1` → Save & Test
2. **Prometheus (AMP)**: Add → Prometheus → URL: `<AMP_ENDPOINT>api/v1` → enable SigV4 → region `us-east-1` → Save & Test
3. **X-Ray**: Add → X-Ray → region `us-east-1` → Save & Test

### Step 6: Import the Kubernetes dashboard

```bash
# In Grafana: Dashboards → Import → ID 315 (Kubernetes cluster monitoring)
# Select the Prometheus data source
```

You will see pod CPU, memory, network, and container restarts for the entire EKS cluster.

---

## Challenge 6 — Find the latency bottleneck with X-Ray

**Goal:** Use X-Ray Analytics to identify which downstream call adds the most latency to `POST /orders`. Apply one targeted optimisation.

### Step 1: Generate realistic load

```bash
ALB_URL=$(kubectl get ingress orderflow -n orderflow \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# 100 order creation requests over 60 seconds
for i in $(seq 1 100); do
  curl -s -X POST "https://${ALB_URL}/orders" \
    -H "Content-Type: application/json" \
    -d "{\"productId\":$((RANDOM % 10 + 1)),\"quantity\":1}" > /dev/null &
  sleep 0.6
done
wait
```

### Step 2: Analyse the service map

In the X-Ray console → **Service Map**:

1. Click the `orderflow-api` node
2. Click **View traces** in the sidebar
3. Filter: `responsetime > 0.1` (traces slower than 100ms)
4. Sort by **Response time** descending

Expected — the slowest traces will show one of:

```
Slowest subsegments in POST /orders:
  postgres.createOrder          → 80ms average
  secretsmanager.GetSecretValue → 35ms average   ← cold start penalty
  sns.Publish                   → 15ms average
```

### Step 3: Identify and fix the bottleneck

The `secretsmanager.GetSecretValue` call on every request is a common issue. The app should cache the secret after the first fetch. In `src/services/database.js`:

```js
// Before: called on every request
const secret = await secretsClient.getSecretValue({ SecretId: process.env.SECRET_ARN }).promise();

// After: cache in module scope — fetched once per Lambda warm container / ECS task
let cachedSecret = null;

async function getDbCredentials() {
  if (cachedSecret) return cachedSecret;
  cachedSecret = JSON.parse(
    (await secretsClient.getSecretValue({ SecretId: process.env.SECRET_ARN }).promise()).SecretString
  );
  return cachedSecret;
}
```

Redeploy:

```bash
docker build --platform linux/amd64 -t orderflow .
GIT_SHA=$(git rev-parse --short HEAD)
docker push "${ECR_URI}:${GIT_SHA}"

helm upgrade orderflow phase-9-eks/helm/orderflow \
  --namespace orderflow \
  --reuse-values \
  --set image.tag="${GIT_SHA}"
```

### Step 4: Re-run the load test and compare

```bash
for i in $(seq 1 100); do
  curl -s -X POST "https://${ALB_URL}/orders" \
    -H "Content-Type: application/json" \
    -d '{"productId":1,"quantity":1}' > /dev/null &
  sleep 0.6
done
wait
```

In X-Ray → Traces → compare the `secretsmanager` subsegment duration before and after.

Expected improvement:

| Metric | Before | After |
|---|---|---|
| `secretsmanager` subsegment | ~35ms | ~0.1ms (cache hit) |
| `POST /orders` p99 | ~120ms | ~75ms |

Record your findings:

```
Latency bottleneck identified: secretsmanager.GetSecretValue — 35ms per request
Fix applied: in-memory secret caching
Measured improvement: p99 reduced from 120ms to 75ms (~37%)
```

---

## AWS concept: the difference between metrics, logs, and traces

| Signal | What it tells you | When to use it |
|---|---|---|
| **Metrics** | Something is wrong (5xx rate spiked at 10:04) | Alerting and dashboards — always on, low cost |
| **Logs** | What happened in a specific service (error message, stack trace) | Debugging after an alert fires |
| **Traces** | The full journey of a specific request across all services | Finding which service caused the slowness or error |

A good debugging workflow: **alarm fires (metric) → check logs → pull trace → fix root cause**.

---

## Outcome

Every request through OrderFlow generates a trace. Failures in any service produce an alarm within 5 minutes. A single Grafana dashboard shows EKS pod health, RDS connections, SQS DLQ depth, and Lambda error rates in one view.

## Cost breakdown

| Resource | $/day |
|---|---|
| Phase 9 baseline (free-tier optimised) | ~$4.53 |
| CloudWatch Logs (~0.5 GB/day ingested) | ~$0.30 |
| Managed Grafana (1 active editor) | ~$0.30 |
| Managed Prometheus | ~$0.10 |
| **Total** | **~$5.23** |

> CloudWatch Logs free tier: 5 GB ingestion/month. Stay within this by setting 7-day log retention on all log groups (already done in the Terraform configs).

```bash
cd terraform && terraform destroy -auto-approve
```

---

[Back to main README](../README.md) | [Next: Phase 11 — Security Hardening](../phase-11-security/README.md)
