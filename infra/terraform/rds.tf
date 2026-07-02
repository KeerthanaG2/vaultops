# rds.tf
# PostgreSQL 15 database for VaultOps audit metadata.
# Lives in private subnets — no direct internet access, reachable only from
# within the VPC (specifically from the EC2 instance via its security group).

# RDS needs a subnet group — tells it which subnets it can use.
# We give it both private subnets across 2 AZs (required by AWS even for
# single-AZ deployments).
resource "aws_db_subnet_group" "vaultops" {
  name       = "vaultops-db-subnet-group"
  subnet_ids = ["subnet-05f56d51d4df04342", "subnet-0ca3e9e4ec9982d00"]

  tags = {
    Name = "vaultops-db-subnet-group"
  }
}

# Security group for RDS.
# Only allows inbound on port 5432 (PostgreSQL) from the EC2 security group.
# Nothing else can reach the database - not even your laptop directly.
resource "aws_security_group" "rds" {
  name        = "vaultops-rds-sg"
  description = "VaultOps RDS security group - only EC2 can connect"
  vpc_id      = "vpc-09fd6e26fffb56bab"

  ingress {
    description     = "PostgreSQL from EC2 only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  # No egress rule needed — RDS doesn't initiate outbound connections.

  tags = {
    Name = "vaultops-rds-sg"
  }
}

# The actual RDS instance.
# db.t3.micro = free tier (750 hrs/month for 12 months).
# No multi-AZ, no read replicas — single instance is correct for a dev/demo project.
# Password is managed by Secrets Manager (see secrets.tf) — NOT hardcoded here.
resource "aws_db_instance" "vaultops" {
  identifier        = "vaultops-db"
  engine            = "postgres"
  engine_version    = "15"
  instance_class    = "db.t3.micro"
  allocated_storage = 20          # GB - minimum, well within free tier
  storage_type      = "gp2"

  db_name  = "vaultops"
  username = "vaultops_user"

  # Password comes from the random_password resource in secrets.tf.
  # Using a reference here keeps everything consistent - one source of truth.
  password = random_password.rds.result

  db_subnet_group_name   = aws_db_subnet_group.vaultops.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Free tier settings:
  multi_az               = false
  publicly_accessible    = false  # never expose DB to internet
  skip_final_snapshot    = true   # allows easy destroy without a final snapshot

  # Automated backups - free tier allows max 1 day retention
  backup_retention_period = 1
  backup_window           = "02:00-03:00" # 2am IST (UTC 20:30)

  tags = {
    Name = "vaultops-db"
  }
}

output "rds_endpoint" {
  description = "RDS connection endpoint — used in DATABASE_URL env var"
  value       = aws_db_instance.vaultops.endpoint
}
