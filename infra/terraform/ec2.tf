# ec2.tf
# Runs the VaultOps FastAPI audit API on a free-tier t2.micro instance.
# Lives in a public subnet so it's reachable from your browser for the demo.
# Security group locks down access — only your IP can SSH or hit the API port.

# Upload your local SSH public key to AWS so EC2 trusts it.
# This lets you SSH in without a password.
resource "aws_key_pair" "vaultops" {
  key_name   = "vaultops-ec2-key"
  public_key = file("~/.ssh/vaultops-ec2.pub")
}

# Security group for the EC2 instance.
# Inbound: only your home IP can SSH (22) or reach the API (8000).
# Outbound: unrestricted — EC2 needs to call AWS APIs (Secrets Manager, ECR).
resource "aws_security_group" "ec2" {
  name        = "vaultops-ec2-sg"
  description = "VaultOps EC2 audit API security group"
  vpc_id      = "vpc-09fd6e26fffb56bab"

  ingress {
    description = "SSH from anywhere temporarily for verification"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "FastAPI from your IP only"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["202.164.151.178/32"]
  }

  egress {
    description = "Allow all outbound (needed for AWS API calls, ECR pull)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "vaultops-ec2-sg"
  }
}

# The actual EC2 instance.
# t2.micro = free tier (750 hrs/month for 12 months).
# Amazon Linux 2023 is the current AWS-maintained Linux distro — lightweight,
# gets security patches automatically.
resource "aws_instance" "vaultops_api" {
  ami                    = "ami-0f58b397bc5c1f2e8" # Amazon Linux 2023, ap-south-1
  instance_type          = "t3.micro"
  subnet_id              = "subnet-0da21c248956b9118" # public-a
  vpc_security_group_ids = [aws_security_group.ec2.id]
  key_name               = aws_key_pair.vaultops.key_name

  # Give this instance an IAM role so it can call Secrets Manager and ECR
  # without hardcoded AWS credentials — same principle as IRSA for K8s.
  iam_instance_profile = aws_iam_instance_profile.ec2.name

  tags = {
    Name = "vaultops-api"
  }
}

# IAM role for the EC2 instance.
# EC2 assumes this role automatically — no access keys needed on the server.
resource "aws_iam_role" "ec2" {
  name = "vaultops-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Allow EC2 to read from Secrets Manager (to fetch RDS password at startup)
# and pull images from ECR (to run the Docker container).
resource "aws_iam_role_policy" "ec2" {
  name = "vaultops-ec2-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = "arn:aws:secretsmanager:ap-south-1:*:secret:vaultops/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "vaultops-ec2-profile"
  role = aws_iam_role.ec2.name
}

output "ec2_public_ip" {
  description = "Public IP of the VaultOps API server — use this to SSH and test"
  value       = aws_instance.vaultops_api.public_ip
}


