# ecr.tf
# Two container image repositories — one for the FastAPI audit API,
# one for the Kubernetes admission webhook.
# ECR is free up to 500MB storage, which is well within our usage.
# IMMUTABLE tags mean once an image is pushed with a tag (e.g. git SHA),
# it can never be overwritten — important for traceability and rollback.

resource "aws_ecr_repository" "api" {
  name                 = "vaultops-api"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    # AWS scans every image push for known CVEs — free and always on.
    scan_on_push = true
  }

  tags = {
    Name = "vaultops-api"
  }
}

resource "aws_ecr_repository" "webhook" {
  name                 = "vaultops-webhook"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "vaultops-webhook"
  }
}

output "ecr_api_url" {
  description = "ECR URL for the audit API image"
  value       = aws_ecr_repository.api.repository_url
}

output "ecr_webhook_url" {
  description = "ECR URL for the webhook image"
  value       = aws_ecr_repository.webhook.repository_url
}
