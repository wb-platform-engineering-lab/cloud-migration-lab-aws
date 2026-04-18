# Phase 7 — Serverless for the Right Problems

> **AWS services introduced:** Lambda, API Gateway, EventBridge Scheduler, Step Functions | **Daily cost:** ~$5.80/day (Lambda within free tier)

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
- **Event-driven functions** that run for seconds in response to a trigger
- **Scheduled jobs** that run on a timer (daily reports, cleanup tasks)
- **Glue code** that connects AWS services without maintaining a server

## When Lambda is the wrong answer

Lambda has cold starts, a 15-minute maximum duration, and an execution model that is fundamentally different from a long-running server. Do not put your order API on Lambda. Keep it on ECS where it belongs.

## What moves to Lambda in this phase

| Current location | What it does | Lambda trigger |
|---|---|---|
| Monolith cron | Generate daily PDF report, email to finance | EventBridge Scheduler (cron) |
| Monolith email service | Send order confirmation emails | SQS (from Phase 6) |
| New | Resize uploaded product images on upload | S3 event notification |
| New | Send low-stock alerts when inventory drops | EventBridge rule |

---

## Challenges

### Challenge 1 — Daily report Lambda with EventBridge Scheduler

**Goal:** Extract the CPU-blocking daily report generator from the monolith into a standalone Lambda. Trigger it at 6 AM UTC daily.

#### Step 1 — Write the Lambda function

Create `phase-7-serverless/lambda/daily-report/index.js`:

```js
const { S3Client, PutObjectCommand } = require('@aws-sdk/client-s3');
const { SESClient, SendEmailCommand } = require('@aws-sdk/client-ses');
const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const { Sequelize, QueryTypes } = require('sequelize');
const PDFDocument = require('pdfkit');

const s3  = new S3Client({ region: process.env.AWS_REGION });
const ses = new SESClient({ region: process.env.AWS_REGION });
const sm  = new SecretsManagerClient({ region: process.env.AWS_REGION });

let sequelize; // reuse across warm invocations

async function getDb() {
  if (sequelize) return sequelize;

  const secret = await sm.send(new GetSecretValueCommand({
    SecretId: process.env.DATABASE_URL_SECRET_ARN,
  }));

  sequelize = new Sequelize(secret.SecretString, {
    dialect: 'postgres',
    logging: false,
    pool: { max: 2, min: 0, idle: 10000 },
  });

  return sequelize;
}

async function queryDailySummary(db, date) {
  const [rows] = await db.query(`
    SELECT
      COUNT(*)::int                    AS total_orders,
      COALESCE(SUM(total_price), 0)    AS total_revenue,
      COALESCE(AVG(total_price), 0)    AS avg_order_value,
      COUNT(DISTINCT customer_id)::int AS unique_customers
    FROM orders
    WHERE DATE(created_at) = :date
      AND status != 'cancelled'
  `, { replacements: { date }, type: QueryTypes.SELECT });

  return rows[0];
}

async function queryTopProducts(db, date) {
  return db.query(`
    SELECT
      p.name,
      SUM(o.quantity)::int   AS units_sold,
      SUM(o.total_price)     AS revenue
    FROM orders o
    JOIN products p ON p.id = o.product_id
    WHERE DATE(o.created_at) = :date
      AND o.status != 'cancelled'
    GROUP BY p.name
    ORDER BY revenue DESC
    LIMIT 5
  `, { replacements: { date }, type: QueryTypes.SELECT });
}

function buildPdf(date, summary, topProducts) {
  return new Promise((resolve, reject) => {
    const doc = new PDFDocument({ margin: 50 });
    const chunks = [];

    doc.on('data', chunk => chunks.push(chunk));
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);

    // Title
    doc.fontSize(20).text(`OrderFlow Daily Report — ${date}`, { align: 'center' });
    doc.moveDown();

    // Summary
    doc.fontSize(14).text('Summary');
    doc.fontSize(11)
      .text(`Total Orders:      ${summary.total_orders}`)
      .text(`Total Revenue:     $${Number(summary.total_revenue).toFixed(2)}`)
      .text(`Avg Order Value:   $${Number(summary.avg_order_value).toFixed(2)}`)
      .text(`Unique Customers:  ${summary.unique_customers}`);
    doc.moveDown();

    // Top products
    doc.fontSize(14).text('Top Products');
    topProducts.forEach((p, i) => {
      doc.fontSize(11).text(
        `${i + 1}. ${p.name} — ${p.units_sold} units — $${Number(p.revenue).toFixed(2)}`
      );
    });

    doc.end();
  });
}

exports.handler = async (event) => {
  const date = event.date || new Date().toISOString().slice(0, 10); // YYYY-MM-DD

  console.log(`[report] Generating report for ${date}`);
  const start = Date.now();

  const db = await getDb();
  const [summary, topProducts] = await Promise.all([
    queryDailySummary(db, date),
    queryTopProducts(db, date),
  ]);

  const pdfBuffer = await buildPdf(date, summary, topProducts);

  // Upload PDF to S3
  const key = `reports/daily/${date}.pdf`;
  await s3.send(new PutObjectCommand({
    Bucket: process.env.REPORTS_BUCKET,
    Key: key,
    Body: pdfBuffer,
    ContentType: 'application/pdf',
  }));

  // Generate a pre-signed download URL (7-day expiry for finance team)
  const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');
  const { GetObjectCommand } = require('@aws-sdk/client-s3');
  const downloadUrl = await getSignedUrl(s3, new GetObjectCommand({
    Bucket: process.env.REPORTS_BUCKET,
    Key: key,
  }), { expiresIn: 604800 });

  // Email the report link to finance
  await ses.send(new SendEmailCommand({
    Source: process.env.SES_FROM_ADDRESS,
    Destination: { ToAddresses: [process.env.FINANCE_EMAIL] },
    Message: {
      Subject: { Data: `OrderFlow Daily Report — ${date}` },
      Body: {
        Text: {
          Data: [
            `Daily report for ${date} is ready.`,
            ``,
            `Summary:`,
            `  Orders:   ${summary.total_orders}`,
            `  Revenue:  $${Number(summary.total_revenue).toFixed(2)}`,
            ``,
            `Download (valid 7 days):`,
            downloadUrl,
          ].join('\n'),
        },
      },
    },
  }));

  const duration = ((Date.now() - start) / 1000).toFixed(1);
  console.log(`[report] Done in ${duration}s. PDF at s3://${process.env.REPORTS_BUCKET}/${key}`);

  return { date, duration: `${duration}s`, s3Key: key };
};
```

Install dependencies:

```bash
cd phase-7-serverless/lambda/daily-report
npm init -y
npm install @aws-sdk/client-s3 @aws-sdk/client-ses @aws-sdk/client-secrets-manager \
            @aws-sdk/s3-request-presigner sequelize pg pdfkit
```

#### Step 2 — Create the S3 reports bucket

Create `phase-7-serverless/terraform/s3_reports.tf`:

```hcl
resource "aws_s3_bucket" "reports" {
  bucket = "orderflow-reports-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "orderflow-reports" }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "expire-old-reports"
    status = "Enabled"

    expiration {
      days = 90
    }
  }
}

output "reports_bucket_name" {
  value = aws_s3_bucket.reports.bucket
}
```

#### Step 3 — IAM role for the report Lambda

Create `phase-7-serverless/terraform/iam_report.tf`:

```hcl
data "aws_iam_policy_document" "lambda_report_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_report" {
  name               = "orderflow-lambda-report"
  assume_role_policy = data.aws_iam_policy_document.lambda_report_trust.json
}

resource "aws_iam_role_policy_attachment" "lambda_report_logs" {
  role       = aws_iam_role.lambda_report.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# VPC access — Lambda must reach the RDS instance in the private subnet
resource "aws_iam_role_policy_attachment" "lambda_report_vpc" {
  role       = aws_iam_role.lambda_report.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "lambda_report_app" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:orderflow/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.reports.arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_report_app" {
  name   = "lambda-report-app"
  role   = aws_iam_role.lambda_report.id
  policy = data.aws_iam_policy_document.lambda_report_app.json
}
```

#### Step 4 — Deploy the Lambda and EventBridge Scheduler

Create `phase-7-serverless/terraform/lambda_report.tf`:

```hcl
data "archive_file" "lambda_report" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/daily-report"
  output_path = "${path.module}/lambda-report.zip"
}

resource "aws_lambda_function" "daily_report" {
  filename         = data.archive_file.lambda_report.output_path
  source_code_hash = data.archive_file.lambda_report.output_base64sha256
  function_name    = "orderflow-daily-report"
  role             = aws_iam_role.lambda_report.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  timeout          = 900  # 15 minutes maximum
  memory_size      = 512

  # Lambda must be in the VPC to reach RDS in the private subnet
  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda_report.id]
  }

  environment {
    variables = {
      DATABASE_URL_SECRET_ARN = var.database_url_secret_arn
      REPORTS_BUCKET          = aws_s3_bucket.reports.bucket
      SES_FROM_ADDRESS        = var.ses_from_address
      FINANCE_EMAIL           = var.finance_email
    }
  }

  tags = { Name = "orderflow-daily-report" }
}

# Security group: allow outbound to RDS (5432) and HTTPS (443 for SES/S3)
resource "aws_security_group" "lambda_report" {
  name   = "orderflow-lambda-report"
  vpc_id = var.vpc_id

  egress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
    description = "RDS PostgreSQL"
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS for AWS API calls"
  }
}

# ── EventBridge Scheduler: trigger at 06:00 UTC daily ────────────────────────
resource "aws_scheduler_schedule" "daily_report" {
  name       = "orderflow-daily-report"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"  # Run at exactly 06:00, no flex window
  }

  schedule_expression          = "cron(0 6 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.daily_report.arn
    role_arn = aws_iam_role.scheduler_invoke.arn

    input = jsonencode({
      # date omitted — Lambda uses today's date
    })

    retry_policy {
      maximum_retry_attempts = 2
    }
  }
}

# EventBridge Scheduler needs a role to invoke Lambda
resource "aws_iam_role" "scheduler_invoke" {
  name = "orderflow-scheduler-invoke-report"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "scheduler.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  name = "invoke-daily-report"
  role = aws_iam_role.scheduler_invoke.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.daily_report.arn
    }]
  })
}
```

Apply:

```bash
cd phase-7-serverless/terraform
terraform init
terraform apply -auto-approve
```

#### Step 5 — Test with a manual invocation

```bash
# Invoke for yesterday to avoid empty-data edge case
YESTERDAY=$(date -u -d "yesterday" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)

aws lambda invoke \
  --function-name orderflow-daily-report \
  --payload "{\"date\":\"${YESTERDAY}\"}" \
  --cli-binary-format raw-in-base64-out \
  /tmp/report-response.json

cat /tmp/report-response.json | jq .
```

Expected:

```json
{
  "date": "2026-04-17",
  "duration": "3.2s",
  "s3Key": "reports/daily/2026-04-17.pdf"
}
```

Confirm the PDF landed in S3:

```bash
BUCKET=$(terraform output -raw reports_bucket_name)
aws s3 ls s3://${BUCKET}/reports/daily/
```

Expected:

```
2026-04-17 06:00:03       48271 2026-04-17.pdf
```

---

### Challenge 2 — Measure duration and decide on Step Functions

**Goal:** Confirm the report finishes well within the 15-minute Lambda limit. Understand when Step Functions is the right answer.

#### Step 1 — Measure actual duration

```bash
# Invoke and time it
time aws lambda invoke \
  --function-name orderflow-daily-report \
  --payload "{\"date\":\"$(date -u +%Y-%m-%d)\"}" \
  --cli-binary-format raw-in-base64-out \
  --log-type Tail \
  /tmp/report-response.json \
  --query 'LogResult' \
  --output text | base64 -d | grep -E 'Duration|Billed'
```

Expected output:

```
REPORT RequestId: ...  Duration: 3241.52 ms  Billed Duration: 3242 ms  Memory Size: 512 MB  Max Memory Used: 187 MB
```

For the OrderFlow lab data volume, the report runs in ~3 seconds — well under 15 minutes.

#### Step 2 — When you would use Step Functions

If the report grew to handle millions of rows and required multiple stages, you would split it into a Step Functions state machine:

```
┌─────────────────────────────────────────────────────────────┐
│ State Machine: GenerateDailyReport                          │
│                                                             │
│  QueryOrders → QueryProducts → BuildPdf → EmailReport       │
│      (30s)        (30s)          (60s)       (5s)           │
│                                                             │
│  Each step is a separate Lambda with its own timeout.       │
│  If QueryOrders fails, Step Functions retries it 3×         │
│  before marking the execution as failed.                    │
└─────────────────────────────────────────────────────────────┘
```

The 15-minute Lambda limit applies to a **single invocation**. A Step Functions workflow can run for up to a year, with each individual Lambda staying under 15 minutes.

Create `phase-7-serverless/terraform/stepfunctions.tf` as a reference (not deployed in this lab):

```hcl
# Reference only — deploy if your report exceeds 10 minutes
resource "aws_sfn_state_machine" "daily_report" {
  name     = "orderflow-daily-report"
  role_arn = aws_iam_role.sfn_execution.arn

  definition = jsonencode({
    Comment = "OrderFlow daily report generator"
    StartAt = "QueryOrders"
    States = {
      QueryOrders = {
        Type     = "Task"
        Resource = aws_lambda_function.report_query_orders.arn
        Next     = "BuildPdf"
        Retry = [{
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException"]
          IntervalSeconds = 5
          MaxAttempts     = 3
          BackoffRate     = 2
        }]
      }
      BuildPdf = {
        Type     = "Task"
        Resource = aws_lambda_function.report_build_pdf.arn
        Next     = "EmailReport"
      }
      EmailReport = {
        Type     = "Task"
        Resource = aws_lambda_function.report_send_email.arn
        End      = true
      }
    }
  })
}
```

**Decision rule:** Use a single Lambda when your function runs in under 10 minutes and has no branching logic. Use Step Functions when you need retries per step, parallel branches, human approval steps, or the total workflow exceeds 10 minutes.

---

### Challenge 3 — S3 event: image resize on upload

**Goal:** When a product image is uploaded to `uploads/products/`, automatically resize it to 300×300 and save to `thumbnails/products/`.

#### Step 1 — Write the image resize Lambda

Create `phase-7-serverless/lambda/image-resize/index.js`:

```js
const { S3Client, GetObjectCommand, PutObjectCommand } = require('@aws-sdk/client-s3');
const sharp = require('sharp');

const s3 = new S3Client({ region: process.env.AWS_REGION });

exports.handler = async (event) => {
  const results = [];

  for (const record of event.Records) {
    const bucket = record.s3.bucket.name;
    const key    = decodeURIComponent(record.s3.object.key.replace(/\+/g, ' '));

    // Only process files in uploads/products/
    if (!key.startsWith('uploads/products/')) {
      console.log(`[resize] Skipping ${key} — not in uploads/products/`);
      continue;
    }

    console.log(`[resize] Processing s3://${bucket}/${key}`);

    // Download original
    const { Body, ContentType } = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
    const originalBuffer = Buffer.concat(await Body.toArray());

    // Resize to 300×300, cover crop (no distortion)
    const resized = await sharp(originalBuffer)
      .resize(300, 300, { fit: 'cover', position: 'centre' })
      .jpeg({ quality: 85 })
      .toBuffer();

    // Write thumbnail
    const thumbnailKey = key.replace('uploads/products/', 'thumbnails/products/').replace(/\.[^.]+$/, '.jpg');

    await s3.send(new PutObjectCommand({
      Bucket: bucket,
      Key: thumbnailKey,
      Body: resized,
      ContentType: 'image/jpeg',
      CacheControl: 'public, max-age=31536000, immutable',
    }));

    console.log(`[resize] Thumbnail at s3://${bucket}/${thumbnailKey} (${resized.length} bytes)`);
    results.push({ source: key, thumbnail: thumbnailKey, bytes: resized.length });
  }

  return { results };
};
```

Install the `sharp` dependency (requires native binaries — build for Linux):

```bash
cd phase-7-serverless/lambda/image-resize
npm init -y

# sharp must be installed on linux/amd64 to match the Lambda runtime
npm install --platform=linux --arch=x64 sharp
npm install @aws-sdk/client-s3
```

#### Step 2 — Terraform for the resize Lambda and S3 trigger

Create `phase-7-serverless/terraform/lambda_resize.tf`:

```hcl
data "archive_file" "lambda_resize" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/image-resize"
  output_path = "${path.module}/lambda-resize.zip"
}

resource "aws_iam_role" "lambda_resize" {
  name = "orderflow-lambda-resize"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_resize_logs" {
  role       = aws_iam_role.lambda_resize.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_resize_s3" {
  name = "s3-read-write"
  role = aws_iam_role.lambda_resize.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${var.uploads_bucket_arn}/uploads/products/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${var.uploads_bucket_arn}/thumbnails/products/*"
      }
    ]
  })
}

resource "aws_lambda_function" "image_resize" {
  filename         = data.archive_file.lambda_resize.output_path
  source_code_hash = data.archive_file.lambda_resize.output_base64sha256
  function_name    = "orderflow-image-resize"
  role             = aws_iam_role.lambda_resize.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  timeout          = 30
  memory_size      = 512  # sharp benefits from more memory

  tags = { Name = "orderflow-image-resize" }
}

# Allow S3 to invoke the Lambda
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.image_resize.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = var.uploads_bucket_arn
}

# S3 event notification — trigger on object creation under uploads/products/
resource "aws_s3_bucket_notification" "product_images" {
  bucket = var.uploads_bucket_name

  lambda_function {
    lambda_function_arn = aws_lambda_function.image_resize.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "uploads/products/"
    filter_suffix       = ""  # All image types
  }

  depends_on = [aws_lambda_permission.allow_s3]
}
```

Apply:

```bash
terraform apply -auto-approve
```

#### Step 3 — Test the image resize pipeline

```bash
UPLOADS_BUCKET=$(terraform -chdir=phase-5-static-assets/terraform output -raw uploads_bucket_name)
CF_DOMAIN=$(terraform -chdir=phase-5-static-assets/terraform output -raw cloudfront_domain)

# Upload a test product image
curl -sL "https://via.placeholder.com/1200x800.jpg" -o /tmp/product-test.jpg

aws s3 cp /tmp/product-test.jpg \
  s3://${UPLOADS_BUCKET}/uploads/products/product-1.jpg

echo "Waiting for Lambda to process..."
sleep 5

# Verify the thumbnail was created
aws s3 ls s3://${UPLOADS_BUCKET}/thumbnails/products/
```

Expected:

```
2026-04-18 10:00:05       12847 product-1.jpg
```

Check Lambda logs:

```bash
aws logs tail /aws/lambda/orderflow-image-resize --since 2m
```

Expected:

```
[resize] Processing s3://orderflow-uploads-a1b2c3d4/uploads/products/product-1.jpg
[resize] Thumbnail at s3://orderflow-uploads-a1b2c3d4/thumbnails/products/product-1.jpg (12847 bytes)
```

---

### Challenge 4 — Low-stock alert Lambda

**Goal:** When inventory drops below 10 units, publish an SNS alert. Trigger from the `order-inventory` SQS queue after each order is processed.

#### Step 1 — Write the Lambda

Create `phase-7-serverless/lambda/low-stock-alert/index.js`:

```js
const { SNSClient, PublishCommand } = require('@aws-sdk/client-sns');
const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const { Sequelize, QueryTypes } = require('sequelize');

const sns = new SNSClient({ region: process.env.AWS_REGION });
const sm  = new SecretsManagerClient({ region: process.env.AWS_REGION });

const LOW_STOCK_THRESHOLD = parseInt(process.env.LOW_STOCK_THRESHOLD || '10', 10);
const ALERT_TOPIC_ARN     = process.env.ALERT_TOPIC_ARN;

let sequelize;

async function getDb() {
  if (sequelize) return sequelize;
  const secret = await sm.send(new GetSecretValueCommand({
    SecretId: process.env.DATABASE_URL_SECRET_ARN,
  }));
  sequelize = new Sequelize(secret.SecretString, {
    dialect: 'postgres',
    logging: false,
    pool: { max: 2, min: 0, idle: 10000 },
  });
  return sequelize;
}

exports.handler = async (event) => {
  const db = await getDb();

  for (const record of event.Records) {
    const body = JSON.parse(record.body);
    const { productId, quantity } = body;

    if (!productId) continue;

    // Check current stock after this order's deduction
    const [product] = await db.query(
      'SELECT id, name, stock FROM products WHERE id = :id',
      { replacements: { id: productId }, type: QueryTypes.SELECT }
    );

    if (!product) continue;

    console.log(`[low-stock] Product ${product.name}: stock=${product.stock}`);

    if (product.stock <= LOW_STOCK_THRESHOLD) {
      await sns.send(new PublishCommand({
        TopicArn: ALERT_TOPIC_ARN,
        Subject: `Low Stock Alert: ${product.name}`,
        Message: [
          `Product: ${product.name} (ID: ${product.id})`,
          `Current stock: ${product.stock} units`,
          `Threshold: ${LOW_STOCK_THRESHOLD} units`,
          ``,
          `Action required: reorder or adjust pricing.`,
        ].join('\n'),
        MessageAttributes: {
          alertType: { DataType: 'String', StringValue: 'LowStock' },
          productId: { DataType: 'Number', StringValue: String(product.id) },
        },
      }));

      console.log(`[low-stock] Alert published for ${product.name} (stock: ${product.stock})`);
    }
  }
};
```

Install dependencies:

```bash
cd phase-7-serverless/lambda/low-stock-alert
npm init -y
npm install @aws-sdk/client-sns @aws-sdk/client-secrets-manager sequelize pg
```

#### Step 2 — Terraform for the alert Lambda and SNS topic

Create `phase-7-serverless/terraform/lambda_low_stock.tf`:

```hcl
# Alert topic — ops team subscribes their email/PagerDuty here
resource "aws_sns_topic" "low_stock_alerts" {
  name = "orderflow-low-stock-alerts"
  tags = { Name = "orderflow-low-stock-alerts" }
}

resource "aws_sns_topic_subscription" "ops_email" {
  topic_arn = aws_sns_topic.low_stock_alerts.arn
  protocol  = "email"
  endpoint  = var.ops_email
}

data "archive_file" "lambda_low_stock" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/low-stock-alert"
  output_path = "${path.module}/lambda-low-stock.zip"
}

resource "aws_iam_role" "lambda_low_stock" {
  name = "orderflow-lambda-low-stock"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_low_stock_logs" {
  role       = aws_iam_role.lambda_low_stock.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_low_stock_sqs" {
  role       = aws_iam_role.lambda_low_stock.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_low_stock_vpc" {
  role       = aws_iam_role.lambda_low_stock.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_low_stock_app" {
  name = "low-stock-app"
  role = aws_iam_role.lambda_low_stock.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:orderflow/*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.low_stock_alerts.arn
      }
    ]
  })
}

resource "aws_lambda_function" "low_stock_alert" {
  filename         = data.archive_file.lambda_low_stock.output_path
  source_code_hash = data.archive_file.lambda_low_stock.output_base64sha256
  function_name    = "orderflow-low-stock-alert"
  role             = aws_iam_role.lambda_low_stock.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  timeout          = 30
  memory_size      = 256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda_report.id]
  }

  environment {
    variables = {
      DATABASE_URL_SECRET_ARN = var.database_url_secret_arn
      ALERT_TOPIC_ARN         = aws_sns_topic.low_stock_alerts.arn
      LOW_STOCK_THRESHOLD     = "10"
    }
  }

  tags = { Name = "orderflow-low-stock-alert" }
}

# Trigger: inventory SQS queue (same queue as Phase 6)
resource "aws_lambda_event_source_mapping" "inventory_low_stock" {
  event_source_arn = var.order_inventory_queue_arn
  function_name    = aws_lambda_function.low_stock_alert.arn
  batch_size       = 10
}
```

Apply:

```bash
terraform apply -auto-approve
```

#### Step 3 — Test by draining stock

```bash
# Place enough orders to drop product 1 below the threshold
for i in $(seq 1 8); do
  curl -s -X POST http://your-alb-hostname/orders \
    -H "Content-Type: application/json" \
    -b cookies.txt \
    -d '{"productId":1,"quantity":1}' > /dev/null
  echo "Order $i placed"
done

# Check Lambda logs for the alert
sleep 10
aws logs tail /aws/lambda/orderflow-low-stock-alert --since 2m
```

Expected:

```
[low-stock] Product Widget Pro: stock=9
[low-stock] Alert published for Widget Pro (stock: 9)
```

You'll receive an email at the `ops_email` address from SNS.

---

### Challenge 5 — Remove cron code from the monolith

**Goal:** Delete the report cron job from the Node.js app. Measure the CPU baseline improvement.

#### Step 1 — Remove the cron scheduler from the app

In `orderflow/src/app.js`, remove the cron setup entirely:

```js
// DELETE these lines:
const cron = require('node-cron');
cron.schedule('0 6 * * *', async () => {
  await generateDailyReport();
});
```

Remove `node-cron` from dependencies:

```bash
cd orderflow
npm uninstall node-cron
```

#### Step 2 — Remove the report route (optional)

The `/orders/reports/daily` HTTP endpoint was useful for manual triggers. It can remain for emergency use, but the scheduled invocation now comes from EventBridge, not a cron inside the process.

If you want to keep it for manual triggers, add a guard so it can only be called by internal tooling:

```js
// In orderflow/src/routes/orders.js
router.get('/reports/daily', requireInternalToken, async (req, res) => {
  const report = await generateDailyReport();
  res.json({ status: 'ok', ...report });
});

function requireInternalToken(req, res, next) {
  const token = req.headers['x-internal-token'];
  if (token !== process.env.INTERNAL_TOKEN) {
    return res.status(403).json({ error: 'Forbidden' });
  }
  next();
}
```

#### Step 3 — Measure CPU baseline before and after

Before (with cron running at 6 AM):

```bash
# Capture CPU during report generation (old monolith behaviour)
docker stats orderflow --no-stream --format "{{.CPUPerc}}"
# Trigger the report manually
curl -s http://localhost:3000/orders/reports/daily > /dev/null &
sleep 5
docker stats orderflow --no-stream --format "{{.CPUPerc}}"
```

Example output showing the event loop blocked:

```
Before trigger:  2.3%
During report:   94.7%    ← burnCpu() + PDF generation blocking the event loop
```

After (Lambda handles the report, monolith is untouched):

```bash
docker stats orderflow --no-stream --format "{{.CPUPerc}}"
```

Expected:

```
Idle baseline:   2.1%    ← flat, no report processing
```

#### Step 4 — Deploy the updated monolith

```bash
cd orderflow
git add src/app.js package.json package-lock.json
git commit -m "feat: remove cron report generator — moved to Lambda"
git push origin main
```

The CI/CD pipeline (Phase 4) picks up the change, builds a new image, and deploys to ECS automatically.

---

## AWS concept: Lambda pricing model

Lambda charges per request ($0.0000002/request) and per GB-second of compute time ($0.0000166667/GB-second).

The report generator at 512 MB RAM running for 3 seconds:
- `0.5 GB × 3s = 1.5 GB-seconds × $0.0000166667 = $0.000025 per run`
- Running daily: **$0.0075/month** (~$0.00025/day)

The same workload keeping a dedicated EC2 instance running 24/7: **$15+/month**.

Lambda's economics are compelling for intermittent workloads. The crossover point is roughly: if your function runs more than ~20% of the time, a persistent container is cheaper.

## Outcome

The monolith no longer runs any cron jobs or non-request-path logic. The event-driven email and report functions are independently deployable. Container CPU profiles are flat during peak hours.

## Cost breakdown

| Resource | $/day |
|---|---|
| Phase 6 baseline | ~$5.80 |
| Lambda + EventBridge | ~$0 (within free tier) |
| **Total** | **~$5.80** |

---

[Back to main README](../README.md) | [Next: Phase 8 — Auth with Cognito](../phase-8-cognito/README.md)
