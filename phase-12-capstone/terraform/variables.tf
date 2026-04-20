variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name"
  type        = string
  default     = "orderflow"
}

variable "environment" {
  description = "Environment name — set via tfvars file per workspace"
  type        = string
}

# ── EC2 / EKS ────────────────────────────────────────────────────────────────
variable "ec2_instance_type" {
  description = "EC2 instance type for app servers"
  type        = string
  default     = "t2.micro"
}

variable "eks_node_type" {
  description = "EKS node instance type"
  type        = string
  default     = "t3.small"
}

variable "eks_node_min" {
  description = "EKS node group minimum size"
  type        = number
  default     = 1
}

variable "eks_node_max" {
  description = "EKS node group maximum size"
  type        = number
  default     = 3
}

variable "eks_node_desired" {
  description = "EKS node group desired size"
  type        = number
  default     = 1
}

# ── RDS ───────────────────────────────────────────────────────────────────────
variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "rds_multi_az" {
  description = "Enable Multi-AZ for RDS (true for prod only)"
  type        = bool
  default     = false
}

variable "rds_snapshot_identifier" {
  description = "Restore RDS from this snapshot ID (leave empty for fresh instance)"
  type        = string
  default     = ""
}

# ── WAF ────────────────────────────────────────────────────────────────────────
variable "enable_waf" {
  description = "Attach WAF Web ACL to the ALB"
  type        = bool
  default     = false
}

# ── NAT ───────────────────────────────────────────────────────────────────────
variable "nat_type" {
  description = "NAT type: 'instance' (free tier) or 'gateway' (managed, $2.16/day)"
  type        = string
  default     = "instance"

  validation {
    condition     = contains(["instance", "gateway"], var.nat_type)
    error_message = "nat_type must be 'instance' or 'gateway'."
  }
}

# ── GitHub Actions OIDC ───────────────────────────────────────────────────────
variable "github_org" {
  description = "GitHub organisation or username"
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
  default     = "cloud-migration-lab-aws"
}
