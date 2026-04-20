# NAT Instance — free-tier t2.micro replacing the $2.16/day NAT Gateway pair.
#
# Trade-offs vs NAT Gateway:
#   - Single point of failure per VPC (no per-AZ redundancy)
#   - Max throughput ~1 Gbps vs NAT Gateway's elastic scaling
#   - Requires manual patching
# These are acceptable for a dev/lab environment.
# For production, switch back to aws_nat_gateway resources.

# AWS-maintained AMI: Amazon Linux 2 pre-configured for IP forwarding and NAT masquerade
data "aws_ami" "nat_instance" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn-ami-vpc-nat-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_security_group" "nat_instance" {
  name        = "${var.project}-nat-instance-sg"
  description = "NAT instance — allows private subnets outbound internet access"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "All traffic from private subnets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [
      aws_subnet.private[0].cidr_block,
      aws_subnet.private[1].cidr_block,
    ]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project}-nat-instance-sg"
  }
}

# t2.micro: free tier eligible — 750 hrs/month for first 12 months
resource "aws_instance" "nat" {
  ami                         = data.aws_ami.nat_instance.id
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.nat_instance.id]
  source_dest_check           = false # Must be disabled — NAT forwards packets between subnets
  associate_public_ip_address = true

  iam_instance_profile = aws_iam_instance_profile.ec2_instance.name

  tags = {
    Name = "${var.project}-nat-instance"
  }
}

# Elastic IP — keeps the NAT instance at a stable public IP across reboots
resource "aws_eip" "nat_instance" {
  domain   = "vpc"
  instance = aws_instance.nat.id

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.project}-nat-instance-eip"
  }
}

# Private route tables — both private subnets route outbound through the NAT instance ENI
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.main.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.nat.primary_network_interface_id
  }

  tags = {
    Name = "${var.project}-private-rt-${count.index + 1}"
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
