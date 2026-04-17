# Phase 9 — EKS: The Platform Layer

> **AWS services introduced:** EKS, ALB Ingress Controller, EBS CSI Driver, IRSA, Karpenter | **Daily cost:** ~$9.60/day

## Objective

Move long-running API services from ECS to Kubernetes. ECS works for a single team — EKS is the answer when multiple teams need namespace isolation, RBAC, NetworkPolicies, and a standard deployment model.

## AWS services

| Service | Why we need it |
|---|---|
| **EKS** | Managed Kubernetes control plane |
| **AWS Load Balancer Controller** | Creates ALBs from Kubernetes `Ingress` resources |
| **EBS CSI Driver** | Provisions EBS persistent volumes for stateful workloads |
| **IRSA** | Binds Kubernetes ServiceAccounts to IAM roles (no shared credentials) |
| **Karpenter** | Provisions the right EC2 instance type for each workload automatically |

## Terraform structure

```
terraform/
├── eks_cluster.tf   # EKS cluster + managed node group
├── irsa.tf          # OIDC provider + IAM roles per service
├── karpenter.tf     # Karpenter installation + node class
└── variables.tf
```

## Helm charts

```
charts/
├── orderflow-orders/      # Orders API Helm chart
├── orderflow-inventory/   # Inventory service Helm chart
└── orderflow-warehouse/   # Warehouse notifier Helm chart
```

## What moves to EKS

| Workload | Before | After |
|---|---|---|
| Orders API | ECS Service | EKS Deployment |
| Inventory Service | ECS Service | EKS Deployment |
| Warehouse Notifier | ECS Service | EKS Deployment |
| Report Generator | Lambda | Lambda (unchanged) |
| Static Assets | CloudFront/S3 | CloudFront/S3 (unchanged) |

## Key concept: IRSA

```
Pod (ServiceAccount: orders-api)
  → AssumeRoleWithWebIdentity
      → EKS OIDC provider validates the token
          → IAM Role: orders-api-role
              → Secrets Manager: orderflow/db-password
```

One IAM role per service. No credentials in environment variables. No shared instance profiles.

## Challenges

1. Provision an EKS cluster with managed node groups via Terraform
2. Install the AWS Load Balancer Controller via Helm
3. Deploy the Orders API as a Helm chart with an `Ingress` resource (ALB annotations)
4. Configure IRSA for the Orders API — bind its ServiceAccount to an IAM role with Secrets Manager read access
5. Install Karpenter — configure a NodePool and EC2NodeClass
6. Apply NetworkPolicies: default-deny-all in the `orderflow` namespace, then explicit allow rules between services

## Outcome

All long-running services run on EKS with namespace isolation, RBAC, and NetworkPolicies. New services are deployed with `helm install` — no manual AWS console work.

## Cost breakdown

| Resource | $/day |
|---|---|
| 2× NAT Gateway | $2.16 |
| EKS control plane | $2.40 |
| 2× EC2 t3.medium nodes | $2.00 |
| RDS + ElastiCache + ALB | $2.29 |
| CloudFront + S3 | ~$0.06 |
| **Total** | **~$8.91** |

```bash
cd terraform && terraform destroy -auto-approve
```

---

[Back to main README](../README.md)
