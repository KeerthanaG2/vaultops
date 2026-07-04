resource "random_password" "rds" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}?"
}

resource "aws_secretsmanager_secret" "rds" {
  name                    = "vaultops/rds-password"
  description             = "VaultOps RDS credentials — auto-rotated by Lambda"
  recovery_window_in_days = 0

  tags = {
    Name = "vaultops-rds-secret"
  }
}

resource "aws_secretsmanager_secret_version" "rds" {
  secret_id = aws_secretsmanager_secret.rds.id

  secret_string = jsonencode({
    host     = aws_db_instance.vaultops.address
    port     = 5432
    dbname   = "vaultops"
    username = "vaultops_user"
    password = random_password.rds.result
  })
}

output "secret_arn" {
  description = "ARN of the RDS secret"
  value       = aws_secretsmanager_secret.rds.arn
}