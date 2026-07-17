terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Projeto    = "InvoiceIQ"
      Ambiente   = "Estudos"
      Gerenciado = "Terraform"
    }
  }
}

resource "aws_s3_bucket" "invoiceiq_bucket" {
  bucket = "invoiceiq-entrada-vieiraniz"
  force_destroy = true
}

resource "aws_sqs_queue" "invoiceiq_dlq" {
  name                      = "invoiceiq-dlq"
  message_retention_seconds = 1209600 
}

resource "aws_sqs_queue" "invoiceiq_queue" {
  name = "invoiceiq-queue"
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.invoiceiq_dlq.arn
    maxReceiveCount     = 3 
  })
}

resource "aws_dynamodb_table" "invoiceiq_table" {
  name         = "invoiceiq-dados-extraidos"
  billing_mode = "PAY_PER_REQUEST" 
  hash_key     = "document_id"     

  attribute {
    name = "document_id"
    type = "S" 
  }
}

resource "aws_iam_role" "lambda_execution_role" {
  name = "invoiceiq-lambda-role"
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

resource "aws_iam_policy" "lambda_strict_policy" {
  name        = "invoiceiq-lambda-strict-policy"
  description = "Permissoes minimas para o pipeline InvoiceIQ"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.invoiceiq_bucket.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.invoiceiq_queue.arn
      },
      {
        Effect = "Allow"
        Action = [
          "textract:AnalyzeExpense",
          "textract:AnalyzeDocument"
        ]
        Resource = "*" 
      },
      {
        Effect = "Allow"
        Action = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.invoiceiq_table.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_attach" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = aws_iam_policy.lambda_strict_policy.arn
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "../src/processor/lambda_function.py"
  output_path = "lambda_function.zip"
}

resource "aws_lambda_function" "invoiceiq_processor" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "invoiceiq-processor"
  role             = aws_iam_role.lambda_execution_role.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 30 
  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.invoiceiq_table.name
    }
  }
}

resource "aws_sqs_queue_policy" "s3_to_sqs_policy" {
  queue_url = aws_sqs_queue.invoiceiq_queue.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action = "sqs:SendMessage"
        Resource = aws_sqs_queue.invoiceiq_queue.arn
        Condition = {
          ArnEquals = { "aws:SourceArn" = aws_s3_bucket.invoiceiq_bucket.arn }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.invoiceiq_bucket.id
  queue {
    queue_arn     = aws_sqs_queue.invoiceiq_queue.arn
    events        = ["s3:ObjectCreated:*"]
  }
  depends_on = [aws_sqs_queue_policy.s3_to_sqs_policy]
}

resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.invoiceiq_queue.arn
  function_name    = aws_lambda_function.invoiceiq_processor.arn
  batch_size       = 1 
}

output "bucket_de_entrada" {
  description = "Nome do bucket para onde voce deve enviar os PDFs de teste"
  value       = aws_s3_bucket.invoiceiq_bucket.bucket
}
