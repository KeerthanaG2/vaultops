# iam.tf
# IAM role for the VaultOps webhook pod.
# In real EKS this would use OIDC-based IRSA — the K8s service account token
# is exchanged for an AWS IAM role via the OIDC provider attached to EKS.
# Since we use Minikube locally, we simulate this by allowing our admin user
# to assume this role for local dev. The trust policy comment shows what the
# real OIDC version looks like.

resource "aws_iam_role" "webhook" {
  name = "vaultops-webhook-role"

  # Trust policy: who can assume this role.
  # LOCAL DEV VERSION (Minikube): allows our vaultops-admin IAM user to assume it.
  # REAL EKS VERSION would look like this instead:
  # {
  #   "Effect": "Allow",
  #   "Principal": {
  #     "Federated": "arn:aws:iam::269531437067:oidc-provider/oidc.eks.ap-south-1.amazonaws.com/id/XXXXX"
  #   },
  #   "Action": "sts:AssumeRoleWithWebIdentity",
  #   "Condition": {
  #     "StringEquals": {
  #       "oidc.eks.ap-south-1.amazonaws.com/id/XXXXX:sub": "system:serviceaccount:vaultops:vaultops-webhook-sa"
  #     }
  #   }
  # }
  # The Condition is what makes it secure — only the specific K8s service account
  # in the specific namespace can assume this role. Nothing else.

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::269531437067:user/vaultops-admin"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "vaultops-webhook-role"
  }
}

# What the webhook role is allowed to DO once it assumes the role.
# Scoped tightly — only GetSecretValue and DescribeSecret on vaultops/* secrets.
# Nothing else. If the webhook is compromised, it can't touch any other AWS resource.
resource "aws_iam_role_policy" "webhook" {
  name = "vaultops-webhook-policy"
  role = aws_iam_role.webhook.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSecretsRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        # Only secrets with the vaultops/ prefix — not any other secret in the account
        Resource = "arn:aws:secretsmanager:ap-south-1:269531437067:secret:vaultops/*"
      }
    ]
  })
}

output "webhook_role_arn" {
  description = "ARN of the webhook IAM role — annotated on K8s ServiceAccount"
  value       = aws_iam_role.webhook.arn
}
