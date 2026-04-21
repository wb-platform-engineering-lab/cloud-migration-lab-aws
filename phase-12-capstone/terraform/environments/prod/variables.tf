variable "environment" { type = string }
variable "aws_region" { type = string }
variable "ec2_instance_type" { type = string }
variable "rds_instance_class" { type = string }
variable "rds_multi_az" { type = bool }
variable "eks_node_type" { type = string }
variable "eks_node_min" { type = number }
variable "eks_node_max" { type = number }
variable "eks_node_desired" { type = number }
variable "enable_waf" { type = bool }
variable "nat_type" { type = string }
variable "rds_snapshot_identifier" { type = string; default = null }
