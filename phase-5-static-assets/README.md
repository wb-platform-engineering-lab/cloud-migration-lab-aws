# Phase 5 — Extract Static Assets to S3 + CloudFront

> **AWS services introduced:** S3 (assets), CloudFront, pre-signed URLs | **Daily cost:** ~$6.40/day

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

## Challenges

1. Create an S3 bucket for static assets with public access blocked (all access goes through CloudFront)
2. Create a CloudFront distribution with an Origin Access Control (OAC) pointing at the S3 bucket
3. Upload the OrderFlow static assets to S3. Update the app's static file references to use the CloudFront URL.
4. Implement order attachment upload: generate a pre-signed S3 URL in the API, return it to the browser, browser uploads directly to S3 — the file never passes through your application server.
5. Set cache-control headers: `max-age=31536000` for versioned assets (JS/CSS with content hashes), `max-age=3600` for product images
6. Invalidate the CloudFront cache for a specific path after an update — observe the cost ($0.005/1000 invalidation paths) and understand why versioned filenames are better

## Outcome

Static assets are served from CloudFront at edge. The ECS container CPU drops noticeably. Order attachment uploads bypass the app server. Deploying a new version of the app does not affect static asset availability.

## Cost breakdown

| Resource | $/day |
|---|---|
| Phase 4 baseline | ~$5.74 |
| S3 assets bucket | ~$0.01 |
| CloudFront | ~$0.05 |
| **Total** | **~$5.80** |

```bash
cd terraform && terraform destroy -auto-approve
```

---

[Back to main README](../README.md) | [Next: Phase 6 — Async with SQS/SNS](../phase-6-async/README.md)
