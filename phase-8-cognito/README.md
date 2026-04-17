# Phase 8 — Extract Auth to Cognito

> **AWS services introduced:** Cognito User Pools, Cognito Identity Pools, ALB authentication | **Daily cost:** ~$6.40/day (<50K MAU free)

## Objective

Replace the custom session-based auth system with Cognito. The monolith stops handling login, registration, and session management entirely. The ALB enforces authentication before requests reach the containers.

## AWS services

| Service | Why we need it |
|---|---|
| **Cognito User Pools** | Managed user directory — sign-up, sign-in, MFA, password reset |
| **Cognito Identity Pools** | Maps authenticated users to temporary AWS credentials |
| **ALB authentication** | Enforces login at the load balancer before requests reach ECS |

## Terraform structure

```
terraform/
├── cognito.tf       # User Pool, App Client, hosted UI domain
├── alb_auth.tf      # ALB listener rule: authenticate-cognito action
└── variables.tf
```

## How ALB authentication works

```
Browser → GET /orders (no token) → ALB
ALB → redirect to Cognito hosted UI
User logs in → Cognito returns auth code to ALB
ALB exchanges code for tokens → sets auth cookie
Browser → GET /orders (with cookie) → ALB
ALB → ECS with X-Amzn-Oidc-Data header (signed JWT)
ECS reads user identity from JWT header — no session store needed
```

## Challenges

1. Create a Cognito User Pool with email sign-in, optional MFA, and a hosted UI
2. Configure the ALB listener with the `authenticate-cognito` action
3. Migrate existing users: export from PostgreSQL, import via `AdminCreateUser` API
4. Update OrderFlow to read user identity from the `X-Amzn-Oidc-Data` JWT header
5. Remove custom auth routes (`/login`, `/logout`, `/register`) from the monolith
6. Remove the ElastiCache session store dependency from the app (ElastiCache remains for query caching)

## Outcome

Auth is fully managed by Cognito. The monolith has no auth code. MFA is available to all users with zero additional code.

## Cost breakdown

| Resource | $/day |
|---|---|
| Phase 7 baseline | ~$5.80 |
| Cognito | ~$0 (<50,000 MAU free) |
| **Total** | **~$5.80** |

```bash
cd terraform && terraform destroy -auto-approve
```

---

[Back to main README](../README.md)
