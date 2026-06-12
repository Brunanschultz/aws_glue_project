
# 1. Require the AWS provider from the Terraform Registry
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# 2. Configure the AWS Provider block
provider "aws" {
  region = "us-east-1"
}

variable "bucket_name" {
  description = "The name of bucket"
  type = string
  default = "learning-aws-etl-bruna-novais-2026"
}

resource "aws_s3_bucket" "learning-aws-etl" {
  bucket = var.bucket_name

  tags = {
    Name        = "My bucket"
    Environment = "Dev"
  }
}


resource "aws_s3_object" "extract" {
    bucket = var.bucket_name
    key    = "extract/"
    source = "${path.module}/main.py"
}

resource "aws_s3_object" "load" {
    bucket = var.bucket_name
    key    = "load/main.py"
    source = "${path.module}/main.py"
}

# Compacta o código da Lambda
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/lambda_function.py"
  output_path = "${path.module}/lambda.zip"
}

# Role da Lambda
resource "aws_iam_role" "lambda_role" {
  name = "lambda-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Permissão para escrever logs no CloudWatch
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lambda
resource "aws_lambda_function" "activate-s3" {
  function_name = "activate-s3"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  role    = aws_iam_role.lambda_role.arn
  handler = "lambda_function.lambda_handler"
  runtime = "python3.12"

  timeout     = 30
  memory_size = 128
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.activate-s3.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.learning-aws-etl.arn
}


resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.learning-aws-etl.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.activate-s3.arn

    events = [
      "s3:ObjectCreated:*"
    ]

    filter_prefix = "extract/"
  }

  depends_on = [
    aws_lambda_permission.allow_s3
  ]
}