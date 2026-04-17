# Phase 4 — CI/CD Pipeline

> **AWS services introduced:** ECR image scanning | **Daily cost:** ~$6.35/day

## Objective

Automate the path from `git push` to production. Every commit goes through lint, test, build, vulnerability scan, and deploy — without an engineer running a single command.

## Pipeline design

```
git push
  └── Lint (ESLint + hadolint)
        └── Unit tests (Jest)
              └── docker build (linux/amd64)
                    └── Trivy scan (CRITICAL + HIGH → exit 1 on CVE)
                          ├── [CVEs found] → Fail — block merge
                          └── [Clean] → Push to ECR (:sha + :latest)
                                  └── ECS update-service --force-new-deployment
                                            └── Wait for stability (aws ecs wait services-stable)
```

## Workflow structure

```
.github/workflows/
├── ci.yml      # Lint, test, build, scan, push to ECR
└── cd.yml      # Deploy to ECS on merge to main
```

## Key concept: OIDC federation (no static keys)

```
GitHub Actions → AssumeRoleWithWebIdentity (JWT) → AWS STS
                                                        └── Validate against GitHub OIDC endpoint
                                                                └── Temporary credentials (15 min TTL)
```

Never store AWS access keys as GitHub secrets. OIDC issues temporary credentials that expire — nothing to leak, nothing to rotate.

## Challenges

1. Set up GitHub Actions OIDC trust with AWS (IAM OIDC provider + role with trust policy)
2. Write the CI workflow: lint → test → build → Trivy scan → push to ECR
3. Write the CD step: update ECS task definition with new image SHA, force deployment, wait for stability
4. Add `workflow_dispatch` input for promoting a specific SHA to staging
5. Protect `main`: require all status checks to pass before merge
6. Simulate a CVE: add a vulnerable npm package — confirm the pipeline fails and blocks the push

## Outcome

Every push to `main` automatically builds, scans, and deploys to dev. CVEs in the image block the deploy before it reaches ECS.

## Cost breakdown

| Resource | $/day |
|---|---|
| Phase 3 baseline | ~$5.69 |
| ECR image storage (~5 images) | ~$0.05 |
| **Total** | **~$5.74** |

> GitHub Actions minutes are free for public repos. Private repos: 2,000 free minutes/month on the free plan.

---

[Back to main README](../README.md)
