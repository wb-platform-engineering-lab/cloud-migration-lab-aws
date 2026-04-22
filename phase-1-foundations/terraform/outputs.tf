output "vpc_id" {
  description = "VPC ID — referenced by all subsequent phases"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB, NAT instance)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (app servers, databases)"
  value       = aws_subnet.private[*].id
}

output "nat_instance_public_ip" {
  description = "NAT instance public IP (assigned at launch)"
  value       = aws_instance.nat.public_ip
}

output "ec2_instance_profile_name" {
  description = "Instance profile name for app EC2 instances"
  value       = aws_iam_instance_profile.ec2_instance.name
}
