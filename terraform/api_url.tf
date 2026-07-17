data "archive_file" "api_url_zip" {
  type        = "zip"
  source_file = "../src/api/generate_url.py"
  output_path = "api_url_function.zip"
}

resource "aws_lambda_function" "invoiceiq_url_api_function" {
  filename         = data.archive_file.api_url_zip.output_path
  function_name    = "invoiceiq-api-generate-url"
  role             = aws_iam_role.lambda_execution_role.arn
  handler          = "generate_url.lambda_handler"
  source_code_hash = data.archive_file.api_url_zip.output_base64sha256
  runtime          = "python3.12"
  
  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.invoiceiq_bucket.bucket
    }
  }
}

resource "aws_apigatewayv2_api" "url_http_api" {
  name          = "invoiceiq-url-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "OPTIONS"]
    allow_headers = ["*"]
  }
}

resource "aws_apigatewayv2_integration" "url_api_integration" {
  api_id           = aws_apigatewayv2_api.url_http_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.invoiceiq_url_api_function.invoke_arn
}

resource "aws_apigatewayv2_route" "url_api_route" {
  api_id    = aws_apigatewayv2_api.url_http_api.id
  route_key = "GET /url"
  target    = "integrations/${aws_apigatewayv2_integration.url_api_integration.id}"
}

resource "aws_lambda_permission" "url_api_gw_permission" {
  statement_id  = "AllowURLAPIInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.invoiceiq_url_api_function.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.url_http_api.execution_arn}/*/*"
}

resource "aws_apigatewayv2_stage" "url_api_stage" {
  api_id      = aws_apigatewayv2_api.url_http_api.id
  name        = "$default"
  auto_deploy = true
}

output "presigned_url_endpoint" {
  description = "URL publica para gerar os PDFs"
  value       = "${aws_apigatewayv2_api.url_http_api.api_endpoint}/url"
}
