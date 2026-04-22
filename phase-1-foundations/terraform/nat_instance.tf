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
  description = "NAT instance - inbound from VPC, outbound to internet"

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.10.0.0/16"]
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