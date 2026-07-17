# ==========================================
# 1. ALOJAMENTO ESTÁTICO (S3 WEBSITE)
# ==========================================

# Bucket S3 para alojar o index.html
resource "aws_s3_bucket" "frontend_bucket" {
  bucket        = "invoiceiq-frontend-darleiniz" # Garanta que este nome é globalmente único
  force_destroy = true
}

# Configuração de Site Estático no S3
resource "aws_s3_bucket_website_configuration" "frontend_website" {
  bucket = aws_s3_bucket.frontend_bucket.id

  index_document {
    suffix = "index.html"
  }
  
}

# Desbloquear o acesso público ao bucket do website
resource "aws_s3_bucket_public_access_block" "frontend_public_block" {
  bucket = aws_s3_bucket.frontend_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Política para permitir que qualquer pessoa na internet leia o index.html
resource "aws_s3_bucket_policy" "frontend_policy" {
  bucket     = aws_s3_bucket.frontend_bucket.id
  depends_on = [aws_s3_bucket_public_access_block.frontend_public_block]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend_bucket.arn}/*"
      }
    ]
  })
}

# ==========================================
# 2. LAMBDA DE LEITURA (READER)
# ==========================================

# Compactar o código do Reader
data "archive_file" "reader_zip" {
  type        = "zip"
  source_file = "../src/reader/lambda_function.py"
  output_path = "lambda_reader.zip"
}

# Role do IAM específica para a Lambda de Leitura (Garante o Least Privilege)
resource "aws_iam_role" "reader_role" {
  name = "invoiceiq-reader-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Policy restrita: Permite APENAS ler a tabela do DynamoDB e gerar logs
resource "aws_iam_policy" "reader_policy" {
  name        = "invoiceiq-reader-policy"
  description = "Permite apenas leitura da tabela do InvoiceIQ"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Scan"]
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

resource "aws_iam_role_policy_attachment" "reader_attach" {
  role       = aws_iam_role.reader_role.name
  policy_arn = aws_iam_policy.reader_policy.arn
}

# A Função Lambda de Leitura
resource "aws_lambda_function" "invoiceiq_reader" {
  filename         = data.archive_file.reader_zip.output_path
  function_name    = "invoiceiq-reader"
  role             = aws_iam_role.reader_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  timeout          = 10
  source_code_hash = data.archive_file.reader_zip.output_base64sha256

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.invoiceiq_table.name
    }
  }
}

# ==========================================
# 3. EXPOR A API (API GATEWAY)
# ==========================================

# API Gateway HTTP (Mais rápido, moderno e barato que REST API)
resource "aws_apigatewayv2_api" "http_api" {
  name          = "invoiceiq-api"
  protocol_type = "HTTP"
}

# Integração do Gateway com a Lambda de Leitura
resource "aws_apigatewayv2_integration" "api_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"

  connection_type      = "INTERNET"
  description          = "Integracao com a Lambda de Leitura"
  integration_method   = "POST"
  integration_uri      = aws_lambda_function.invoiceiq_reader.invoke_arn
  payload_format_version = "2.0"
}

# Rota para expor o endpoint GET /invoices
resource "aws_apigatewayv2_route" "api_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "GET /invoices"
  target    = "integrations/${aws_apigatewayv2_integration.api_integration.id}"
}


# Permissão para o API Gateway chamar a Lambda
resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.invoiceiq_reader.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# ==========================================
# 4. SAÍDAS NO TERMINAL (OUTPUTS)
# ==========================================
# ==========================================
output "api_endpoint" {
  description = "URL publica da API para colocar no index.html"
  value       = "${aws_apigatewayv2_api.http_api.api_endpoint}/invoices"
}

output "url_do_website" {
  description = "Link público para aceder ao seu Frontend"
  value       = "http://${aws_s3_bucket_website_configuration.frontend_website.website_endpoint}"
}

# Stage padrão limpo (Garante compatibilidade e sucesso no deploy)
resource "aws_apigatewayv2_stage" "api_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}
