# cloudtrail.tf
# Immutable audit log of every AWS API call made in this account.
# Specifically useful for VaultOps — every GetSecretValue call (who accessed
# which secret, when) gets logged here automatically by AWS. No extra code needed.
# This is the compliance artifact that makes VaultOps production-ready.

# S3 bucket where CloudTrail writes its log files.
# Versioning is enabled — log files can't be silently overwritten or deleted.
resource "aws_s3_bucket" "audit_logs" {
  bucket        = "vaultops-audit-logs-269531437067"
  force_destroy = true  # allows terraform destroy to delete even with logs inside

  tags = {
    Name = "vaultops-audit-logs"
  }
}

resource "aws_s3_bucket_versioning" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Block all public access — audit logs must never be publicly readable.
resource "aws_s3_bucket_public_access_block" "audit_logs" {
  bucket                  = aws_s3_bucket.audit_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle rule — move logs to Glacier after 90 days (much cheaper storage),
# delete after 365 days. Keeps costs zero while retaining audit history.
resource "aws_s3_bucket_lifecycle_configuration" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id

  rule {
    id     = "audit-log-lifecycle"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

# S3 bucket policy — CloudTrail requires very specific permissions to write logs.
# The two conditions (SourceArn and SourceAccount) are mandatory — without them
# AWS rejects the policy. This prevents other accounts' CloudTrails from writing
# to your bucket (confused deputy attack protection).
resource "aws_s3_bucket_policy" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = "arn:aws:s3:::vaultops-audit-logs-269531437067"
        Condition = {
          StringEquals = {
            "aws:SourceArn" = "arn:aws:cloudtrail:ap-south-1:269531437067:trail/vaultops-trail"
          }
        }
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::vaultops-audit-logs-269531437067/AWSLogs/269531437067/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:aws:cloudtrail:ap-south-1:269531437067:trail/vaultops-trail"
          }
        }
      }
    ]
  })
}

# The actual CloudTrail trail.
# Logs ALL management events — every AWS API call (CreateSecret, GetSecretValue,
# RunInstances, etc.) is recorded with who called it, when, and from where.
# include_global_service_events catches IAM calls which happen globally.
# log_file_validation_enabled means each log file gets a hash — you can prove
# logs haven't been tampered with (required for SOC2 compliance).
resource "aws_cloudtrail" "vaultops" {
  name                          = "vaultops-trail"
  s3_bucket_name                = aws_s3_bucket.audit_logs.id
  include_global_service_events = true
  is_multi_region_trail         = false  # single region keeps it simple + free
  enable_log_file_validation    = true   # tamper detection

  depends_on = [aws_s3_bucket_policy.audit_logs]

  tags = {
    Name = "vaultops-trail"
  }
}

output "audit_logs_bucket" {
  description = "S3 bucket where CloudTrail audit logs are stored"
  value       = aws_s3_bucket.audit_logs.id
}

output "cloudtrail_arn" {
  description = "ARN of the VaultOps CloudTrail trail"
  value       = aws_cloudtrail.vaultops.arn
}
