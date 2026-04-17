# Phase 5 — Extract Static Assets to S3 + CloudFront

> **AWS services introduced:** S3 (assets), CloudFront, pre-signed URLs | **Daily cost:** ~$6.40/day

## Objective

Move product images, CSS, and JavaScript out of the ECS container and into S3 + CloudFront. The container stops serving files and focuses entirely on API requests.

## AWS services

| Service | Why we need it |
|---|---|
| **S3** | Stores static files outside the application container |
| **CloudFront** | CDN — serves files from 600+ edge locations globally |
| **S3 pre-signed URLs** | Time-limited upload/download links that bypass the app server |

## Terraform structure

```
terraform/
├── s3_assets.tf     # Static assets bucket (public access blocked)
├── cloudfront.tf    # CloudFront distribution + Origin Access Control
└── variables.tf
```

## Before and after

```
Before:
  Browser → ALB → ECS (serves /public/images/product-123.jpg)

After:
  Browser → CloudFront edge → S3 (product-123.jpg from nearest PoP)
  Browser → ALB → ECS (API requests only)
```

## Challenges

1. Create an S3 bucket with public access blocked — all access goes through CloudFront via Origin Access Control (OAC)
2. Create a CloudFront distribution pointing at the S3 bucket
3. Upload OrderFlow static assets to S3. Update the app to reference the CloudFront URL.
4. Implement order attachment upload: generate a pre-signed URL in the API, return it to the browser, browser uploads directly to S3 (file never passes through the app server)
5. Set cache-control headers: `max-age=31536000` for versioned assets, `max-age=3600` for product images
6. Invalidate a CloudFront path after an update — observe the cost and understand why versioned filenames are better

## Outcome

Static assets served from CloudFront at edge. ECS container CPU drops noticeably. Order attachment uploads bypass the app server entirely.

## Cost breakdown

| Resource | $/day |
|---|---|
| Phase 4 baseline | ~$5.74 |
| S3 assets bucket | ~$0.01 |
| CloudFront | ~$0.05 (minimal traffic) |
| **Total** | **~$5.80** |

```bash
cd terraform && terraform destroy -auto-approve
```

---

[Back to main README](../README.md)
