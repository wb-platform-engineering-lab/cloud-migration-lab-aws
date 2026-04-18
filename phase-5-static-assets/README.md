# Phase 5 — Extract Static Assets to S3 + CloudFront

> **AWS services introduced:** S3 (assets), CloudFront, pre-signed URLs | **Daily cost:** ~$5.80/day

---

## AWS services introduced

| Service | What it does | Why we need it |
|---|---|---|
| **S3** | Object storage | Stores static files (images, CSS, JS) outside the app container |
| **CloudFront** | CDN | Caches static files at edge locations globally, reduces latency |
| **S3 pre-signed URLs** | Time-limited access to private objects | Let users upload/download order attachments without routing through the app |

## The problem

The OrderFlow monolith currently serves product images, CSS, and JavaScript from its own process. This means:
- Static files consume CPU and memory in the same container as the business logic
- A deploy replaces all containers simultaneously — users experience a brief gap where static assets are unavailable
- Users in London downloading a 5 MB product image are hitting servers in `us-east-1`

## How it works after this phase

```
Before:
  Browser → ALB → ECS (serves /public/images/product-123.jpg)

After:
  Browser → CloudFront → S3 (serves product-123.jpg from nearest edge)
  Browser → ALB → ECS (only handles API requests and HTML)
```

CloudFront has 600+ edge locations. An image cached at a Frankfurt edge point is served from Frankfurt — not from a US data centre. Page load times drop for international users without any application changes.

---

## Challenges

### Challenge 1 — S3 bucket for static assets

**Goal:** Create a private S3 bucket. All public access goes through CloudFront, never directly to S3.

#### Step 1 — Create the Terraform file

Create `phase-5-static-assets/terraform/s3.tf`:

```hcl
# ── Random suffix for a globally unique bucket name ───────────────────────────
resource "random_id" "assets_suffix" {
  byte_length = 4
}

# ── S3 bucket ─────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "assets" {
  bucket = "orderflow-assets-${random_id.assets_suffix.hex}"

  tags = { Name = "orderflow-assets" }
}

# Block ALL public access — CloudFront uses OAC (IAM), not public ACLs
resource "aws_s3_bucket_public_access_block" "assets" {
  bucket = aws_s3_bucket.assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning keeps old asset versions alive during rolling deploys
resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Lifecycle: expire old non-current versions after 30 days
resource "aws_s3_bucket_lifecycle_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

output "assets_bucket_name" {
  value = aws_s3_bucket.assets.bucket
}
```

#### Step 2 — Apply and verify

```bash
cd phase-5-static-assets/terraform
terraform init
terraform apply -auto-approve
```

Expected output:

```
aws_s3_bucket.assets: Creating...
aws_s3_bucket.assets: Creation complete after 3s [id=orderflow-assets-a1b2c3d4]
aws_s3_bucket_public_access_block.assets: Creation complete after 1s
aws_s3_bucket_versioning.assets: Creation complete after 1s

Outputs:
assets_bucket_name = "orderflow-assets-a1b2c3d4"
```

Confirm public access is truly blocked:

```bash
BUCKET=$(terraform output -raw assets_bucket_name)

aws s3api get-public-access-block --bucket "$BUCKET" \
  --query 'PublicAccessBlockConfiguration'
```

Expected:

```json
{
  "BlockPublicAcls": true,
  "IgnorePublicAcls": true,
  "BlockPublicPolicy": true,
  "RestrictPublicBuckets": true
}
```

Try a direct public GET — it must fail:

```bash
curl -si "https://${BUCKET}.s3.amazonaws.com/test" | head -5
```

Expected:

```
HTTP/2 403
```

---

### Challenge 2 — CloudFront distribution with Origin Access Control

**Goal:** Create a CloudFront distribution that has exclusive read access to S3 via OAC. No other caller can read objects directly.

#### Step 1 — Create the CloudFront Terraform file

Create `phase-5-static-assets/terraform/cloudfront.tf`:

```hcl
# ── Origin Access Control (replaces the legacy OAI) ──────────────────────────
# OAC signs requests to S3 using SigV4 — more secure than the old Origin Access Identity.
resource "aws_cloudfront_origin_access_control" "assets" {
  name                              = "orderflow-assets-oac"
  description                       = "OAC for orderflow assets bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ── CloudFront distribution ───────────────────────────────────────────────────
resource "aws_cloudfront_distribution" "assets" {
  enabled             = true
  comment             = "orderflow-assets"
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # US + Europe only — cheapest

  origin {
    domain_name              = aws_s3_bucket.assets.bucket_regional_domain_name
    origin_id                = "s3-orderflow-assets"
    origin_access_control_id = aws_cloudfront_origin_access_control.assets.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-orderflow-assets"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # Use the AWS-managed CachingOptimized policy
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # Immutable assets (JS/CSS with content hashes) — 1 year TTL
  ordered_cache_behavior {
    path_pattern           = "/static/*"
    target_origin_id       = "s3-orderflow-assets"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    response_headers_policy_id = aws_cloudfront_response_headers_policy.immutable.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "orderflow-assets" }
}

# ── Response headers: immutable cache for hashed assets ──────────────────────
resource "aws_cloudfront_response_headers_policy" "immutable" {
  name = "orderflow-immutable-assets"

  custom_headers_config {
    items {
      header   = "Cache-Control"
      value    = "public, max-age=31536000, immutable"
      override = true
    }
  }
}

# ── S3 bucket policy: only allow CloudFront OAC ──────────────────────────────
data "aws_iam_policy_document" "assets_bucket_policy" {
  statement {
    sid    = "AllowCloudFrontOAC"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.assets.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.assets.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "assets" {
  bucket = aws_s3_bucket.assets.id
  policy = data.aws_iam_policy_document.assets_bucket_policy.json
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.assets.domain_name
}

output "cloudfront_id" {
  value = aws_cloudfront_distribution.assets.id
}
```

#### Step 2 — Apply

```bash
terraform apply -auto-approve
```

CloudFront distributions take 3–5 minutes to deploy globally.

Expected output:

```
aws_cloudfront_origin_access_control.assets: Creating...
aws_cloudfront_distribution.assets: Creating...
aws_cloudfront_distribution.assets: Still creating... [3m0s elapsed]
aws_cloudfront_distribution.assets: Creation complete after 4m12s

Outputs:
cloudfront_domain = "d1234abcd5678.cloudfront.net"
cloudfront_id     = "E1A2B3C4D5E6F7"
```

#### Step 3 — Verify OAC is the only path to S3

Upload a test object directly to S3:

```bash
BUCKET=$(terraform output -raw assets_bucket_name)
CF_DOMAIN=$(terraform output -raw cloudfront_domain)

echo "Hello CloudFront" > /tmp/test.txt
aws s3 cp /tmp/test.txt s3://${BUCKET}/test.txt

# Should succeed via CloudFront
curl -si "https://${CF_DOMAIN}/test.txt" | head -10
```

Expected:

```
HTTP/2 200
x-cache: Miss from cloudfront    ← first request: cache miss, fetched from S3
content-type: text/plain

Hello CloudFront
```

Second request (cache hit):

```bash
curl -si "https://${CF_DOMAIN}/test.txt" | grep -E 'HTTP|x-cache'
```

Expected:

```
HTTP/2 200
x-cache: Hit from cloudfront
```

Direct S3 access must still be denied:

```bash
curl -si "https://${BUCKET}.s3.amazonaws.com/test.txt" | head -3
```

Expected:

```
HTTP/2 403
```

---

### Challenge 3 — Upload static assets and update app references

**Goal:** Move the OrderFlow `public/` directory to S3 and update the app to serve static asset URLs from CloudFront.

#### Step 1 — Sync existing static assets to S3

```bash
BUCKET=$(terraform output -raw assets_bucket_name)
CF_DOMAIN=$(terraform output -raw cloudfront_domain)

# Sync the orderflow public directory
aws s3 sync orderflow/public/ s3://${BUCKET}/public/ \
  --cache-control "public, max-age=3600" \
  --exclude "*.md"
```

Expected output:

```
upload: orderflow/public/css/style.css to s3://orderflow-assets-a1b2c3d4/public/css/style.css
upload: orderflow/public/js/app.js to s3://orderflow-assets-a1b2c3d4/public/js/app.js
upload: orderflow/public/images/logo.png to s3://orderflow-assets-a1b2c3d4/public/images/logo.png
```

Verify they are accessible via CloudFront:

```bash
curl -si "https://${CF_DOMAIN}/public/css/style.css" | head -5
```

#### Step 2 — Add `STATIC_BASE_URL` to the app

Add to `orderflow/src/app.js` (in the middleware section, before routes):

```js
// Make the static asset base URL available in all templates
app.locals.staticBase = process.env.STATIC_BASE_URL || '';
```

Update `orderflow/docker-compose.yml` — add the env var to the app service:

```yaml
environment:
  STATIC_BASE_URL: ""   # Empty in local dev — serves from /public directly
```

For ECS (in the task definition or via Secrets Manager), set:

```
STATIC_BASE_URL=https://d1234abcd5678.cloudfront.net
```

Store the CloudFront domain in Secrets Manager so the pipeline picks it up:

```bash
CF_DOMAIN=$(terraform output -raw cloudfront_domain)

aws secretsmanager create-secret \
  --name orderflow/static-base-url \
  --secret-string "https://${CF_DOMAIN}" \
  --region us-east-1
```

#### Step 3 — Update the ECS task definition

Add the secret to the `secrets` array in the task definition (in `phase-3-ecs/terraform/ecs.tf`):

```hcl
secrets = [
  { name = "DATABASE_URL",    valueFrom = aws_secretsmanager_secret.database_url.arn },
  { name = "REDIS_URL",       valueFrom = aws_secretsmanager_secret.redis_url.arn },
  { name = "SESSION_SECRET",  valueFrom = aws_secretsmanager_secret.session_secret.arn },
  { name = "STATIC_BASE_URL", valueFrom = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:orderflow/static-base-url" },
]
```

Grant the ECS task execution role permission to read the new secret:

```hcl
# In iam.tf, update the Secrets Manager resource list
resources = [
  "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:orderflow/*"
]
```

This wildcard already covers `orderflow/static-base-url` if you used that pattern in Phase 3.

#### Step 4 — Remove static file serving from Express

In `orderflow/src/app.js`, the static middleware serves files only when `STATIC_BASE_URL` is not set (local dev):

```js
// Serve static files in local dev; in production, CloudFront serves from S3
if (!process.env.STATIC_BASE_URL) {
  app.use(express.static(path.join(__dirname, '../public')));
}
```

#### Step 5 — Add to CI: sync assets on every deploy

Append a step to the `deploy` job in `.github/workflows/ci.yml`:

```yaml
      - name: Sync static assets to S3
        run: |
          aws s3 sync orderflow/public/ s3://${{ vars.ASSETS_BUCKET }}/public/ \
            --cache-control "public, max-age=3600" \
            --delete \
            --exclude "*.md"
          echo "Assets synced to S3"
```

Add `ASSETS_BUCKET` as a GitHub Actions variable (Settings → Variables):

```bash
BUCKET=$(terraform output -raw assets_bucket_name)
echo "Add GitHub Actions variable: ASSETS_BUCKET = $BUCKET"
```

---

### Challenge 4 — Pre-signed URLs for order attachments

**Goal:** Let customers upload files (invoices, receipts) directly from their browser to S3. The file never passes through the application server.

#### Step 1 — Create a separate private bucket for user uploads

Create `phase-5-static-assets/terraform/s3_uploads.tf`:

```hcl
resource "aws_s3_bucket" "uploads" {
  bucket = "orderflow-uploads-${random_id.assets_suffix.hex}"
  tags   = { Name = "orderflow-uploads" }
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CORS: allow browsers to PUT directly to S3
resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "GET"]
    allowed_origins = ["https://${var.app_domain}"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}

# Lifecycle: delete unconfirmed uploads after 7 days
resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    id     = "expire-pending-uploads"
    status = "Enabled"

    expiration {
      days = 7
    }
  }
}

output "uploads_bucket_name" {
  value = aws_s3_bucket.uploads.bucket
}
```

Grant the ECS task role permission to generate pre-signed URLs:

```hcl
# In phase-3-ecs/terraform/iam.tf, add to the task role policy:
statement {
  effect = "Allow"
  actions = [
    "s3:PutObject",
    "s3:GetObject",
  ]
  resources = [
    "arn:aws:s3:::orderflow-uploads-*/*"
  ]
}
```

Apply:

```bash
terraform apply -auto-approve
```

#### Step 2 — Add pre-signed URL endpoint to the app

Create `orderflow/src/routes/uploads.js`:

```js
const express = require('express');
const { S3Client, PutObjectCommand, GetObjectCommand } = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');
const { requireAuth } = require('../middleware/auth');

const router = express.Router();

const s3 = new S3Client({ region: process.env.AWS_REGION || 'us-east-1' });
const UPLOADS_BUCKET = process.env.UPLOADS_BUCKET;

// POST /uploads/presign — returns a pre-signed PUT URL
// The browser uses this URL to upload directly to S3.
router.post('/presign', requireAuth, async (req, res) => {
  const { filename, contentType, orderId } = req.body;

  if (!filename || !contentType || !orderId) {
    return res.status(400).json({ error: 'filename, contentType, and orderId are required' });
  }

  // Scope uploads to the order + customer to prevent enumeration
  const key = `orders/${orderId}/${req.session.customerId}/${Date.now()}-${filename}`;

  const command = new PutObjectCommand({
    Bucket: UPLOADS_BUCKET,
    Key: key,
    ContentType: contentType,
  });

  // URL expires in 5 minutes — enough for the browser to complete the upload
  const uploadUrl = await getSignedUrl(s3, command, { expiresIn: 300 });

  res.json({
    uploadUrl,
    key,
    expiresIn: 300,
  });
});

// GET /uploads/:key — returns a pre-signed GET URL for downloading
router.get('/:key(*)', requireAuth, async (req, res) => {
  const key = req.params.key;

  const command = new GetObjectCommand({
    Bucket: UPLOADS_BUCKET,
    Key: key,
  });

  // Download links expire in 1 hour
  const downloadUrl = await getSignedUrl(s3, command, { expiresIn: 3600 });

  res.json({ downloadUrl, expiresIn: 3600 });
});

module.exports = router;
```

Install the AWS SDK v3 packages:

```bash
cd orderflow
npm install @aws-sdk/client-s3 @aws-sdk/s3-request-presigner
```

Mount the router in `orderflow/src/app.js`:

```js
const uploadsRouter = require('./routes/uploads');
app.use('/uploads', uploadsRouter);
```

#### Step 3 — Test the pre-signed URL flow

```bash
# 1. Get a pre-signed upload URL from the API
PRESIGN=$(curl -s -X POST http://localhost:3000/uploads/presign \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{"filename":"invoice.pdf","contentType":"application/pdf","orderId":"42"}')

echo "$PRESIGN" | jq .

UPLOAD_URL=$(echo "$PRESIGN" | jq -r .uploadUrl)
KEY=$(echo "$PRESIGN" | jq -r .key)

# 2. Upload directly to S3 using the pre-signed URL (simulates browser PUT)
curl -X PUT "$UPLOAD_URL" \
  -H "Content-Type: application/pdf" \
  --data-binary @/tmp/test-invoice.pdf \
  -w "\nHTTP status: %{http_code}\n"
```

Expected:

```json
{
  "uploadUrl": "https://orderflow-uploads-a1b2c3d4.s3.amazonaws.com/orders/42/7/1705000000000-invoice.pdf?X-Amz-Algorithm=...",
  "key": "orders/42/7/1705000000000-invoice.pdf",
  "expiresIn": 300
}

HTTP status: 200
```

The file is now in S3. The application server handled 0 bytes of the file transfer.

---

### Challenge 5 — Cache-Control headers

**Goal:** Set appropriate cache lifetimes: long for versioned assets (they never change), short for images that might be updated.

#### Step 1 — Upload with explicit cache-control headers

```bash
BUCKET=$(terraform output -raw assets_bucket_name)

# Versioned static assets (JS/CSS with content hash in filename) — cache for 1 year
aws s3 sync orderflow/public/static/ s3://${BUCKET}/static/ \
  --cache-control "public, max-age=31536000, immutable" \
  --metadata-directive REPLACE

# Product images — cache for 1 hour (may change when product is updated)
aws s3 sync orderflow/public/images/ s3://${BUCKET}/images/ \
  --cache-control "public, max-age=3600" \
  --metadata-directive REPLACE
```

#### Step 2 — Verify the headers reach the browser

```bash
CF_DOMAIN=$(terraform output -raw cloudfront_domain)

# Static (should show max-age=31536000)
curl -si "https://${CF_DOMAIN}/static/app.abc123.js" | grep -i cache-control

# Image (should show max-age=3600)
curl -si "https://${CF_DOMAIN}/images/logo.png" | grep -i cache-control
```

Expected:

```
cache-control: public, max-age=31536000, immutable
cache-control: public, max-age=3600
```

#### Step 3 — Understand why immutable matters

`immutable` tells the browser: "Don't even send a conditional request (`If-None-Match`) for this file. I guarantee it will never change at this URL." The browser skips the network entirely on subsequent page loads.

This only works correctly when you use **content-addressed filenames** (e.g., `app.abc123.js` where `abc123` is a hash of the file contents). When the file changes, its hash changes, so the URL changes — browsers fetch the new file fresh.

Without `immutable`, browsers send a conditional GET on every page load. Even a `304 Not Modified` response adds ~50ms of latency per asset.

---

### Challenge 6 — CloudFront cache invalidation

**Goal:** Force CloudFront to fetch a fresh copy of a specific file, then understand why invalidations are a sign of a design smell.

#### Step 1 — Update a file and observe stale cache

```bash
BUCKET=$(terraform output -raw assets_bucket_name)
CF_DOMAIN=$(terraform output -raw cloudfront_domain)

# Upload a new version of the logo
echo "NEW LOGO CONTENT" > /tmp/logo-v2.png
aws s3 cp /tmp/logo-v2.png s3://${BUCKET}/images/logo.png \
  --cache-control "public, max-age=3600" \
  --content-type image/png

# CloudFront still serves the old version (cached at edge)
curl -si "https://${CF_DOMAIN}/images/logo.png" | grep -E 'x-cache|age:'
```

Expected (stale cache):

```
x-cache: Hit from cloudfront
age: 1842
```

#### Step 2 — Invalidate the cached path

```bash
CF_ID=$(terraform output -raw cloudfront_id)

INVALIDATION_ID=$(aws cloudfront create-invalidation \
  --distribution-id "$CF_ID" \
  --paths "/images/logo.png" \
  --query 'Invalidation.Id' \
  --output text)

echo "Invalidation ID: $INVALIDATION_ID"

# Wait for it to complete (~30-60 seconds)
aws cloudfront wait invalidation-completed \
  --distribution-id "$CF_ID" \
  --id "$INVALIDATION_ID"

echo "Invalidation complete"
```

Now fetch again — CloudFront goes back to S3:

```bash
curl -si "https://${CF_DOMAIN}/images/logo.png" | grep -E 'x-cache|age:'
```

Expected:

```
x-cache: Miss from cloudfront
age: 0
```

#### Step 3 — Check the cost

```bash
# View invalidation history
aws cloudfront list-invalidations \
  --distribution-id "$CF_ID" \
  --query 'InvalidationList.Items[*].{id:Id,status:Status,created:CreateTime}' \
  --output table
```

**Invalidation pricing:**
- First 1,000 paths/month: **free**
- Beyond 1,000 paths: **$0.005 per path**
- A wildcard `/*` counts as **one path**

#### Step 4 — The better approach: versioned filenames

```bash
# Instead of overwriting logo.png and invalidating:
# ✗ logo.png          → requires invalidation when changed
# ✓ logo.abc123.png   → new file at new URL, old URL still valid during deploy
# ✓ logo.v2.png       → same idea with a version prefix

# Upload with a version suffix
aws s3 cp /tmp/logo-v2.png \
  s3://${BUCKET}/images/logo.v2.png \
  --cache-control "public, max-age=31536000, immutable"

# Update the app to reference /images/logo.v2.png
# Old clients still load logo.v1.png from CloudFront cache — no disruption
```

**Summary:**

| Approach | Cache TTL | Invalidation needed? | Cost |
|---|---|---|---|
| Non-versioned (`logo.png`) | Short (3600s) | Yes, on every change | $0.005/path after 1K |
| Versioned (`logo.abc123.png`) | Long (31536000s, immutable) | Never | $0 |

The takeaway: design your asset pipeline to produce versioned filenames (webpack, Vite, and most bundlers do this automatically). Reserve invalidations for emergencies — shipping a broken asset that must be pulled from cache immediately.

---

## Outcome

Static assets are served from CloudFront at edge. The ECS container CPU drops noticeably. Order attachment uploads bypass the app server entirely. Deploying a new version of the app does not affect static asset availability.

## Cost breakdown

| Resource | $/day |
|---|---|
| Phase 4 baseline | ~$5.74 |
| S3 assets bucket | ~$0.01 |
| CloudFront | ~$0.05 |
| **Total** | **~$5.80** |

---

[Back to main README](../README.md) | [Next: Phase 6 — Async with SQS/SNS](../phase-6-async/README.md)
