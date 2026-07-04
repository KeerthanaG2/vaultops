resource "null_resource" "build_psycopg2_layer" {
  triggers = {
    requirements = filemd5("../../lambda/rotation/requirements.txt")
    handler      = filemd5("../../lambda/rotation/handler.py")
  }

  provisioner "local-exec" {
    command = join(" && ", [
      "mkdir -p /tmp/psycopg2-layer/python",
      "pip install psycopg2-binary --platform manylinux2014_x86_64 --target /tmp/psycopg2-layer/python --implementation cp --python-version 3.11 --only-binary=:all: --quiet",
      "cd /tmp/psycopg2-layer && zip -r ${path.module}/../../lambda/psycopg2-layer.zip python -q",
      "rm -rf /tmp/psycopg2-layer"
    ])
  }
}

resource "aws_lambda_layer_version" "psycopg2" {
  filename            = "../../lambda/psycopg2-layer.zip"
  layer_name          = "vaultops-psycopg2"
  compatible_runtimes = ["python3.11"]
  depends_on          = [null_resource.build_psycopg2_layer]
  source_code_hash    = filebase64sha256("../../lambda/psycopg2-layer.zip")
}

data "archive_file" "rotation" {
  type        = "zip"
  output_path = "../../lambda/rotation.zip"

  source {
    content  = file("../../lambda/rotation/handler.py")
    filename = "handler.py"
  }
}

resource "aws_iam_role" "lambda_rotation" {
  name = "vaultops-lambda-rotation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_rotation" {
  name = "vaultops-lambda-rotation-policy"
  role = aws_iam_role.lambda_rotation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerAccess"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage",
          "secretsmanager:DescribeSecret"
        ]
        Resource = aws_secretsmanager_secret.rds.arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:ap-south-1:269531437067:log-group:/aws/lambda/vaultops-secret-rotation:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda_rotation.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_security_group" "lambda" {
  name        = "vaultops-lambda-rotation"
  description = "Allow Lambda to reach RDS and Secrets Manager Endpoint"
  vpc_id      = aws_vpc.vaultops.id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "vaultops-lambda-rotation-sg" }
}

resource "aws_security_group_rule" "rds_allow_lambda" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.lambda.id
  description              = "Lambda rotation function to RDS"
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.vaultops.id
  service_name        = "com.amazonaws.ap-south-1.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  security_group_ids  = [aws_security_group.lambda.id]
  private_dns_enabled = true

  tags = { Name = "vaultops-secretsmanager-endpoint" }
}

resource "aws_lambda_function" "rotation" {
  filename         = data.archive_file.rotation.output_path
  source_code_hash = data.archive_file.rotation.output_base64sha256
  function_name    = "vaultops-secret-rotation"
  role             = aws_iam_role.lambda_rotation.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"
  timeout          = 30
  memory_size      = 128

  layers = [aws_lambda_layer_version.psycopg2.arn]

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = { REGION = "ap-south-1" }
  }

  tags = { Name = "vaultops-rotation" }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_vpc_access,
    aws_lambda_layer_version.psycopg2,
    aws_vpc_endpoint.secretsmanager
  ]
}

resource "aws_lambda_permission" "secrets_manager" {
  statement_id  = "AllowSecretsManagerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotation.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = aws_secretsmanager_secret.rds.arn
}

resource "aws_secretsmanager_secret_rotation" "rds" {
  secret_id           = aws_secretsmanager_secret.rds.id
  rotation_lambda_arn = aws_lambda_function.rotation.arn
  rotate_immediately  = false

  rotation_rules {
    automatically_after_days = 30
  }

  depends_on = [aws_lambda_permission.secrets_manager]
}

output "lambda_rotation_arn" {
  description = "ARN of the rotation Lambda"
  value       = aws_lambda_function.rotation.arn
}