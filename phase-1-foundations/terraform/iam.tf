# EC2 IAM role — allows app instances (and the NAT instance) to be managed
# via AWS Systems Manager Session Manager instead of SSH key pairs.

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

resource "aws_iam_role" "ec2_instance" {
  name               = "${var.project}-ec2-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

# SSM managed instance — enables Session Manager, Run Command, and Patch Manager
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance profile wraps the role so EC2 can use it
resource "aws_iam_instance_profile" "ec2_instance" {
  name = "${var.project}-ec2-instance-profile"
  role = aws_iam_role.ec2_instance.name
}
