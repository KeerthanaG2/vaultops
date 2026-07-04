# rds.tf
# PostgreSQL 15 database for VaultOps audit metadata.

resource "aws_db_subnet_group" "vaultops" {
  name       = "vaultops-db-subnet-group"
  subnet_ids = ["subnet-05f56d51d4df04342", "subnet-0ca3e9e4ec9982d00"]

  tags = {
    Name = "vaultops-db-subnet-group"
  }
}

resource "aws_security_group" "rds" {
  name        = "vaultops-rds-sg"
  # Kept exactly the same to allow an in-place modification and avoid ENI detachment locks
  description = "VaultOps RDS security group - only EC2 can connect"
  vpc_id      = "vpc-09fd6e26fffb56bab"

  ingress {
    description     = "PostgreSQL from EC2 only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  ingress {
    description     = "PostgreSQL from Lambda Rotation"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  tags = {
    Name = "vaultops-rds-sg"
  }
}

resource "aws_db_instance" "vaultops" {
  identifier        = "vaultops-db"
  engine            = "postgres"
  engine_version    = "15"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp2"

  db_name  = "vaultops"
  username = "vaultops_user"
  password = random_password.rds.result

  db_subnet_group_name   = aws_db_subnet_group.vaultops.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az            = false
  publicly_accessible = false
  skip_final_snapshot = true

  backup_retention_period = 1
  backup_window           = "02:00-03:00"

  tags = {
    Name = "vaultops-db"
  }
}

output "rds_endpoint" {
  description = "RDS connection endpoint — used in DATABASE_URL env var"
  value       = aws_db_instance.vaultops.endpoint
}
