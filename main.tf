
# 1. Require the AWS provider from the Terraform Registry
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
  }
}

# 2. Configure the AWS Provider block
provider "aws" {
  region = "us-east-1"
  profile = var.aws_profile
}

########### S3 BUCKET ###########
variable "bucket_name" {
  description = "The name of bucket"
  type = string
  default = ""
}

variable "aws_profile" {
  description = "The AWS profile to use for authentication"
  type        = string
  sensitive   = true
}

variable "notification_email" {
  description = "The email for SNS topic subscription"
  type        = string
  sensitive   = true
}

resource "aws_s3_bucket" "learning-aws-etl" {
  bucket = var.bucket_name
}


########### LAMBDA ###########
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/lambda_function.py"
  output_path = "${path.module}/lambda.zip"
}

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

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

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
  eventbridge = true

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

########### GLUE ###########
resource "aws_iam_role" "glue_job_role" {
  name = "glue_job_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_full_access_attach" {
  role       = aws_iam_role.glue_job_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_role_policy_attachment" "glue_service_role" {
  role       = aws_iam_role.glue_job_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

/*resource "aws_s3_object" "python_shell_script" {
  bucket = var.bucket_name
  key    = "glue_jobs/glue_job.py"
  source = "glue/glue_job.py" 
}*/

resource "aws_glue_job" "python_shell_job" {
  name         = "example-python-shell-job"
  description  = "An example Python shell job"
  role_arn     = aws_iam_role.glue_job_role.arn
  max_capacity = "0.0625"
  max_retries  = 0
  timeout      = 2880
  #connections  = [aws_glue_connection.example.name]

  command {
    script_location = "s3://${var.bucket_name}/glue_jobs/glue_job.py"
    name            = "pythonshell"
    python_version  = "3.9"
  }

  default_arguments = {
    "--job-language"                     = "python" # Default is python
    "--continuous-log-logGroup"          = "/aws-glue/jobs"
    "--enable-continuous-cloudwatch-log" = "true"
    "library-set"                        = "analytics" # loads common analytics libraries
  }

  execution_property {
    max_concurrent_runs = 1
  }

  tags = {
    "ManagedBy" = "AWS"
  }
}

########### SNS ###########
module "sns_topic" {
  source  = "terraform-aws-modules/sns/aws"

  name  = "s3-glue-s3-notif"
  display_name = "AWS SNS"

}

resource "aws_sns_topic_subscription" "user_updates_sqs_target" {
  topic_arn = module.sns_topic.topic_arn
  protocol  = "email"
  endpoint  = var.notification_email
}

############# EventBridge ###########

resource "aws_cloudwatch_log_group" "example" {
  name = "/aws/events/s3-create-logs"
}

resource "aws_cloudwatch_log_resource_policy" "eventbridge_logs_policy" {
  policy_name = "AllowEventBridgeToWriteToLogs"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgeToPutEvents"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.example.arn}:*"
      }
    ]
  })
}

resource "aws_iam_role" "eventbridge_sns_role" {
  name = "Amazon_EventBridge_Invoke_Sns_for_s3"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "eventbridge_sns_policy" {
  name = "EventBridgePublishToSNS"
  role = aws_iam_role.eventbridge_sns_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "sns:Publish"
        Effect   = "Allow"
        Resource = module.sns_topic.topic_arn
      }
    ]
  })
}

module "eventbridge" {
  source = "terraform-aws-modules/eventbridge/aws"

  create_bus = false

  targets = {
    s3-create = [
      {
        name            = "SNS topic"
        arn             = module.sns_topic.topic_arn
        attach_role_arn = false
        role_arn        = aws_iam_role.eventbridge_sns_role.arn
      },
      {
        name            = "CloudWatch Log Group"
        arn             = aws_cloudwatch_log_group.example.arn
        attach_role_arn = false
      }
    ]
  }

  rules = {
    s3-create = {
      description   = "Capture log data"
      event_pattern = jsonencode({
        "source"      = ["aws.s3"],
        "detail-type" = ["Object Created"],
        "detail" = {
          "bucket" = {
            "name" = [var.bucket_name]
          }
        }
      })
    }
  }
}
