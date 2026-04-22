# Phase 1 — AWS Foundations

> **AWS services introduced:** VPC, IAM, S3, DynamoDB | **Daily cost:** ~$0.20/day

---

## AWS services introduced

| Service | What it does | Why we need it |
|---|---|---|
| **VPC** | Isolated private network | Nothing in AWS is reachable without a VPC — it is the foundation for everything |
| **IAM** | Identity and access management | Every AWS resource interaction requires an identity and a policy |
| **S3** | Object storage | Stores Terraform state — but also used in every subsequent phase |
| **DynamoDB** | NoSQL key-value store | Provides Terraform state locking |

## The problem

You cannot just start deploying to AWS. You need a network your resources will live in, identities that control who can do what, and a place to store Terraform state that is not your laptop.

## Approach: infrastructure as code from day one

Every resource in this lab is created with Terraform. Never click in the console to create production resources — the console does not version-control what you did or why.

**VPC design:**

```
10.0.0.0/16
├── Public subnets (10.0.1.0/24, 10.0.2.0/24)   — ALB, NAT instance
└── Private subnets (10.0.10.0/24, 10.0.11.0/24) — app servers, databases
```

Public subnets hold load balancers and the NAT instance. Application servers and databases live in private subnets — nothing outside can reach them directly.

---

## Challenge 1 — Create the S3 bucket and DynamoDB lock table

This is the one step you do manually. Terraform cannot store its own state before the bucket exists.

### Step 1: Set your account ID as a variable

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION="us-east-1"
echo "Account: $AWS_ACCOUNT_ID"
```

### Step 2: Create the S3 bucket for Terraform state

```bash
aws s3api create-bucket \
  --bucket "orderflow-tfstate-${AWS_ACCOUNT_ID}" \
  --region $AWS_REGION
```

Enable versioning — this lets you recover from accidental state corruption:

```bash
aws s3api put-bucket-versioning \
  --bucket "orderflow-tfstate-${AWS_ACCOUNT_ID}" \
  --versioning-configuration Status=Enabled
```

Enable server-side encryption:

```bash
aws s3api put-bucket-encryption \
  --bucket "orderflow-tfstate-${AWS_ACCOUNT_ID}" \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
  }'
```

Block all public access:

```bash
aws s3api put-public-access-block \
  --bucket "orderflow-tfstate-${AWS_ACCOUNT_ID}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

### Step 3: Create the DynamoDB lock table

```bash
aws dynamodb create-table \
  --table-name orderflow-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region $AWS_REGION
```

### Step 4: Verify both resources exist

```bash
aws s3api head-bucket --bucket "orderflow-tfstate-${AWS_ACCOUNT_ID}" && echo "Bucket OK"
aws dynamodb describe-table --table-name orderflow-tfstate-lock --query "Table.TableStatus" --output text
```

Expected output:
```
Bucket OK
ACTIVE
```

---

## Challenge 2 — Write Terraform to provision the VPC with public and private subnets across 2 AZs

### Step 1: Create the Terraform directory structure

```bash
mkdir -p phase-1-foundations/terraform
cd phase-1-foundations/terraform
```

### Step 2: Create `backend.tf`

```hcl
# backend.tf
terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "orderflow-tfstate-<YOUR_ACCOUNT_ID>"
    key            = "phase-1/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "orderflow-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}
```

### Step 3: Create `variables.tf`

```hcl
# variables.tf
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name used in resource tags and names"
  type        = string
  default     = "orderflow"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}
```

### Step 4: Create `vpc.tf`

```hcl
# vpc.tf
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "${var.project}-vpc"
    Project     = var.project
    Environment = var.environment
  }
}

# Public subnets — one per AZ
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.project}-public-${count.index + 1}"
    Project     = var.project
    Environment = var.environment
    Tier        = "public"
  }
}

# Private subnets — one per AZ
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name        = "${var.project}-private-${count.index + 1}"
    Project     = var.project
    Environment = var.environment
    Tier        = "private"
  }
}

# Internet Gateway — allows public subnets to reach the internet
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${var.project}-igw"
    Project     = var.project
    Environment = var.environment
  }
}

# Route table for public subnets — sends all traffic to the IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "${var.project}-public-rt"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
```

### Step 5: Initialise Terraform

```bash
terraform init
```

Expected output:
```
Terraform has been successfully initialized!
```

---

## Challenge 3 — Add a NAT instance in the public subnet

A NAT instance is an EC2 instance configured to forward traffic from private subnets to the internet. It serves the same purpose as a NAT gateway but costs ~95% less — making it ideal for labs and non-production environments.

> **NAT instance vs NAT gateway:** A NAT gateway is fully managed, highly available, and scales automatically — but costs $0.045/hour per gateway (~$1.08/day each). A NAT instance is a `t3.nano` EC2 instance ($0.0052/hour, ~$0.12/day) that you manage yourself. For a lab with a single AZ, a NAT instance is the right call.

### Step 1: Add the NAT AMI data source and instance to `vpc.tf`

Append the following to `vpc.tf`:

```hcl
# Look up the latest Amazon Linux 2 AMI
# The old amzn-ami-vpc-nat-* AMIs are deprecated — AL2 with user_data is the modern approach
data "aws_ami" "nat_instance" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# Security group — allow all inbound from the VPC, all outbound to the internet
resource "aws_security_group" "nat" {
  name        = "${var.project}-nat-sg"
  vpc_id      = aws_vpc.main.id
  description = "NAT instance — inbound from VPC, outbound to internet"

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project}-nat-sg"
    Project     = var.project
    Environment = var.environment
  }
}

# NAT instance — must live in a public subnet and have source/dest check disabled
# user_data enables IP forwarding and configures iptables masquerade (replaces the
# deprecated amzn-ami-vpc-nat AMI which did this automatically at boot)
resource "aws_instance" "nat" {
  ami                         = data.aws_ami.nat_instance.id
  instance_type               = "t3.nano"
  subnet_id                   = aws_subnet.public[0].id
  associate_public_ip_address = true
  source_dest_check           = false   # Required — NAT forwards packets for other hosts
  vpc_security_group_ids      = [aws_security_group.nat.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_instance.name

  user_data = <<-EOF
    #!/bin/bash
    # Enable IP forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

    # Masquerade outbound traffic on eth0 so private instances appear as the NAT IP
    yum install -y iptables-services
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    service iptables save
    systemctl enable iptables
  EOF

  tags = {
    Name        = "${var.project}-nat"
    Project     = var.project
    Environment = var.environment
  }

  depends_on = [aws_internet_gateway.main]
}

# Route tables for private subnets — both route through the NAT instance
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.main.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.nat.primary_network_interface_id
  }

  tags = {
    Name        = "${var.project}-private-rt-${count.index + 1}"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
```

> **Cost note:** One `t3.nano` NAT instance costs $0.0052/hour (~$0.12/day). This replaces two NAT gateways that would cost $2.16/day at idle — a 94% reduction for lab use.

---

## Challenge 4 — Create an IAM role for EC2 instances

This role allows EC2 instances to be managed via AWS Systems Manager (SSM) — no SSH key pairs needed.

### Step 1: Create `iam.tf`

```hcl
# iam.tf

# Trust policy — allows EC2 to assume this role
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# IAM role for EC2 instances
resource "aws_iam_role" "ec2_instance" {
  name               = "${var.project}-ec2-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# Attach the SSM managed instance policy
# This allows connecting via Session Manager without SSH keys
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance profile — wraps the role so EC2 can use it
resource "aws_iam_instance_profile" "ec2_instance" {
  name = "${var.project}-ec2-instance-profile"
  role = aws_iam_role.ec2_instance.name

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}
```

---

## Challenge 5 — Run terraform plan and verify all resources

### Step 1: Run the plan

```bash
terraform plan -out=tfplan
```

Review the output carefully. You should see resources planned for creation:

```
Plan: 16 to add, 0 to change, 0 to destroy.

  + aws_vpc.main
  + aws_subnet.public[0]
  + aws_subnet.public[1]
  + aws_subnet.private[0]
  + aws_subnet.private[1]
  + aws_internet_gateway.main
  + aws_route_table.public
  + aws_route_table_association.public[0]
  + aws_route_table_association.public[1]
  + aws_security_group.nat
  + aws_instance.nat
  + aws_route_table.private[0]
  + aws_route_table.private[1]
  + aws_route_table_association.private[0]
  + aws_route_table_association.private[1]
  + aws_iam_role.ec2_instance
  + aws_iam_role_policy_attachment.ssm
  + aws_iam_instance_profile.ec2_instance
```

### Step 2: Check for any issues

- No resources should be modified or destroyed (this is a fresh deployment)
- Every resource should have `Project` and `Environment` tags
- NAT instance should be in a public subnet with `source_dest_check = false`
- Private route tables should reference the NAT instance's network interface, not the IGW

### Step 3: Apply

```bash
terraform apply tfplan
```

The NAT instance is an EC2 instance — it typically becomes available in under 60 seconds. Wait for the apply to complete fully before moving on.

### Step 4: Verify the VPC in the AWS CLI

```bash
# Get the VPC ID
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=orderflow" \
  --query "Vpcs[0].VpcId" \
  --output text)

echo "VPC: $VPC_ID"

# List subnets
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[*].{Name:Tags[?Key=='Name']|[0].Value,CIDR:CidrBlock,AZ:AvailabilityZone,Public:MapPublicIpOnLaunch}" \
  --output table
```

Expected output:
```
-------------------------------------------------------------------
|                        DescribeSubnets                          |
+-------+-------------------+-------------------+----------------+
|  AZ   |       CIDR        |       Name        |    Public      |
+-------+-------------------+-------------------+----------------+
|  a    |  10.0.1.0/24      |  orderflow-public-1  |  True       |
|  b    |  10.0.2.0/24      |  orderflow-public-2  |  True       |
|  a    |  10.0.10.0/24     |  orderflow-private-1 |  False      |
|  b    |  10.0.11.0/24     |  orderflow-private-2 |  False      |
+-------+-------------------+-------------------+----------------+
```

---

## Challenge 6 — Tag every resource with Environment=dev and Project=orderflow

All resources in the Terraform files above already include tags. Verify they were applied correctly:

### Step 1: Check tags on the VPC

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=orderflow" \
  --query "Vpcs[0].Tags" \
  --output table
```

### Step 2: Check tags on the NAT instance

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=orderflow" "Name=tag:Name,Values=orderflow-nat" \
  --query "Reservations[*].Instances[*].{ID:InstanceId,State:State.Name,Tags:Tags}" \
  --output table
```

### Step 3: Add a default tags block to avoid repeating tags on every resource

Update `backend.tf` to add a `default_tags` block to the provider:

```hcl
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
```

With `default_tags`, every resource automatically inherits these tags. Individual resources only need to override or add to them (e.g., `Name`).

Run `terraform apply` again to apply the tag to all existing resources:

```bash
terraform apply -auto-approve
```

---

## AWS concept: Availability Zones

Every AWS region contains multiple Availability Zones — physically separate data centres within the same region. Spreading resources across 2 AZs means a data centre failure does not take down your application. Always provision at least 2 AZs for anything that needs to survive.

## Outcome

A VPC with public/private subnets across 2 AZs, Terraform state in S3 with locking, and IAM roles ready for Phase 2.

## Cost breakdown

| Resource | $/day |
|---|---|
| 1× NAT instance (t3.nano) | ~$0.12 |
| S3 + DynamoDB | ~$0.04 |
| **Total** | **~$0.20** |

> **Always destroy when done.** Even at $0.20/day, leaving this running for a month adds up. NAT gateways would cost $1,620/year at idle — the NAT instance brings that down to ~$44/year.

```bash
cd terraform && terraform destroy -auto-approve
```

---

[Back to main README](../README.md) | [Next: Phase 2 — Lift and Shift](../phase-2-lift-and-shift/README.md)
