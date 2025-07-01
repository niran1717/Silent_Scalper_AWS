# Configure the AWS Provider
provider "aws" {
  region = var.aws_region
}

# Data source to get current AWS partition (e.g., 'aws', 'aws-cn', 'aws-us-gov')
data "aws_partition" "current" {}

# -----------------------------------------------------------------------------
# 1. S3 Buckets Setup
# -----------------------------------------------------------------------------

# S3 Input Bucket for receiving uploaded job files
resource "aws_s3_bucket" "input_bucket" {
  bucket = "${var.s3_input_bucket_name_prefix}-${var.unique_id}"

  # Allow temporary public access via pre-signed URLs for uploads
  # For direct uploads, BlockPublicAcls and IgnorePublicAcls are usually true,
  # but BlockPublicPolicy and RestrictPublicBuckets are false.
  # Here, for simplicity and direct pre-signed URL upload, we relax all.
  # In production, consider stricter policies and direct S3 PutObject from Lambda/API.
  acl = "private" # Start private, pre-signed URLs grant temporary access

  # IMPORTANT: We need to explicitly manage public access blocks for pre-signed URLs to work
  # If you want to allow pre-signed URLs for PUT operations, you must ensure
  # that 'Block all public access' is NOT enabled on the bucket.
  # Terraform's default for aws_s3_bucket_public_access_block is to block all.
  # So, we need to explicitly disable it for this bucket.
  # For a production environment, consider using S3 Transfer Acceleration or other upload methods
  # that don't require relaxing public access blocks.
  # For this learning project, we'll disable it.
  # This block must be commented out or set to false if you want to allow public access.
  # We are setting `block_public_acls = false` and `ignore_public_acls = false`
  # but keeping `block_public_policy = true` and `restrict_public_buckets = true`
  # to prevent truly public anonymous access while allowing pre-signed URL usage.
  # However, the simplest way to allow pre-signed URLs that are PUT-able by anyone
  # is to disable all block public access settings for the bucket.
  # Given the architecture, the pre-signed URL is time-limited, so this is a controlled risk.
}

resource "aws_s3_bucket_public_access_block" "input_bucket_public_access_block" {
  bucket = aws_s3_bucket.input_bucket.id

  # Set all to false to allow pre-signed URLs for PUT operations
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# S3 Quarantine Bucket for invalid files
resource "aws_s3_bucket" "quarantine_bucket" {
  bucket = "${var.s3_quarantine_bucket_name_prefix}-${var.unique_id}"
  acl    = "private" # This bucket should remain private

  # Ensure public access is blocked for the quarantine bucket (default behavior)
  # This resource explicitly sets all public access blocks to true.
  depends_on = [aws_s3_bucket.quarantine_bucket] # Ensure bucket is created first
}

resource "aws_s3_bucket_public_access_block" "quarantine_bucket_public_access_block" {
  bucket = aws_s3_bucket.quarantine_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# 2. DynamoDB Table Setup
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table" "metadata_table" {
  name             = var.dynamodb_table_name
  billing_mode     = "PAY_PER_REQUEST" # On-demand capacity for cost efficiency and free tier
  hash_key         = "JobId"
  range_key        = "ProcessingTimestamp"

  attribute {
    name = "JobId"
    type = "S" # String
  }
  attribute {
    name = "ProcessingTimestamp"
    type = "S" # String
  }

  tags = {
    Project = "SilentScalper"
  }
}

# -----------------------------------------------------------------------------
# 3. IAM Role for Lambda Functions
# -----------------------------------------------------------------------------

# IAM Policy Document for Lambda to assume role
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# IAM Role for Lambda functions
resource "aws_iam_role" "lambda_execution_role" {
  name               = "SilentScalperLambdaRole-${var.unique_id}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Project = "SilentScalper"
  }
}

# Attach basic Lambda execution policy (CloudWatch Logs)
resource "aws_iam_role_policy_attachment" "lambda_basic_execution_policy" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Attach S3 access policy (Full Access for simplicity in this project)
# In production, use a more restrictive policy.
resource "aws_iam_role_policy_attachment" "lambda_s3_access_policy" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonS3FullAccess"
}

# Attach DynamoDB access policy (Full Access for simplicity in this project)
# In production, use a more restrictive policy.
resource "aws_iam_role_policy_attachment" "lambda_dynamodb_access_policy" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonDynamoDBFullAccess"
}

# -----------------------------------------------------------------------------
# 4. Lambda Functions
# -----------------------------------------------------------------------------

# Lambda for generating pre-signed S3 upload URLs
resource "aws_lambda_function" "get_presigned_url_lambda" {
  function_name    = var.get_presigned_url_lambda_name
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.9" # Or python3.10
  role             = aws_iam_role.lambda_execution_role.arn
  timeout          = 30 # seconds
  memory_size      = 128 # MB

  filename         = var.get_presigned_url_lambda_zip_path
  source_code_hash = filebase64sha256(var.get_presigned_url_lambda_zip_path)

  environment {
    variables = {
      S3_INPUT_BUCKET_NAME = aws_s3_bucket.input_bucket.bucket
    }
  }

  tags = {
    Project = "SilentScalper"
  }
}

# Lambda for processing uploaded files (triggered by S3 event)
resource "aws_lambda_function" "file_processor_lambda" {
  function_name    = var.file_processor_lambda_name
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.9" # Or python3.10
  role             = aws_iam_role.lambda_execution_role.arn
  timeout          = 60 # seconds (can be longer for file processing)
  memory_size      = 256 # MB (can be higher for larger files)

  filename         = var.file_processor_lambda_zip_path
  source_code_hash = filebase64sha256(var.file_processor_lambda_zip_path)

  environment {
    variables = {
      S3_QUARANTINE_BUCKET_NAME = aws_s3_bucket.quarantine_bucket.bucket
      DYNAMODB_TABLE_NAME       = aws_dynamodb_table.metadata_table.name
    }
  }

  tags = {
    Project = "SilentScalper"
  }
}

# CloudWatch Log Group for GetPresignedUrlLambda
resource "aws_cloudwatch_log_group" "get_presigned_url_lambda_log_group" {
  name              = "/aws/lambda/${aws_lambda_function.get_presigned_url_lambda.function_name}"
  retention_in_days = 7

  tags = {
    Project = "SilentScalper"
  }
}

# CloudWatch Log Group for FileProcessorLambda
resource "aws_cloudwatch_log_group" "file_processor_lambda_log_group" {
  name              = "/aws/lambda/${aws_lambda_function.file_processor_lambda.function_name}"
  retention_in_days = 7

  tags = {
    Project = "SilentScalper"
  }
}


# -----------------------------------------------------------------------------
# 5. S3 Event Trigger for FileProcessorLambda
# -----------------------------------------------------------------------------

resource "aws_s3_bucket_notification" "s3_file_upload_notification" {
  bucket = aws_s3_bucket.input_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.file_processor_lambda.arn
    events              = ["s3:ObjectCreated:*"] # Trigger on any object creation
    # filter_prefix = "uploads/" # Optional: process only objects in a specific folder
    # filter_suffix = ".json"    # Optional: process only specific file types
  }

  # Grant S3 permission to invoke the Lambda function
  depends_on = [aws_lambda_permission.s3_invoke_file_processor_lambda]
}

# Permission for S3 to invoke FileProcessorLambda
resource "aws_lambda_permission" "s3_invoke_file_processor_lambda" {
  statement_id  = "AllowS3InvokeFileProcessorLambda"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.file_processor_lambda.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.input_bucket.arn
}

# -----------------------------------------------------------------------------
# 6. API Gateway Setup
# -----------------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "silent_scalper_api" {
  name        = var.api_gateway_name
  description = "API for Silent Scalper to get pre-signed S3 upload URLs."

  tags = {
    Project = "SilentScalper"
  }
}

# API Gateway Resource (/upload)
resource "aws_api_gateway_resource" "upload_resource" {
  rest_api_id = aws_api_gateway_rest_api.silent_scalper_api.id
  parent_id   = aws_api_gateway_rest_api.silent_scalper_api.root_resource_id
  path_part   = "upload"
}

# API Gateway POST Method for /upload
resource "aws_api_gateway_method" "upload_post_method" {
  rest_api_id   = aws_api_gateway_rest_api.silent_scalper_api.id
  resource_id   = aws_api_gateway_resource.upload_resource.id
  http_method   = "POST"
  authorization = "NONE" # No authorization for public upload URL generation
}

# API Gateway Integration with GetPresignedUrlLambda (Lambda Proxy)
resource "aws_api_gateway_integration" "upload_lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.silent_scalper_api.id
  resource_id             = aws_api_gateway_resource.upload_resource.id
  http_method             = aws_api_gateway_method.upload_post_method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY" # Crucial for Lambda Proxy Integration
  uri                     = aws_lambda_function.get_presigned_url_lambda.invoke_arn
}

# Permission for API Gateway to invoke GetPresignedUrlLambda
resource "aws_lambda_permission" "api_gateway_invoke_presigned_url_lambda" {
  statement_id  = "AllowAPIGatewayInvokePresignedUrlLambda"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_presigned_url_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  # The /*/* part is important: it allows invocation from any method/resource in the API
  source_arn    = "${aws_api_gateway_rest_api.silent_scalper_api.execution_arn}/*/*"
}

# API Gateway OPTIONS Method for CORS preflight
resource "aws_api_gateway_method" "upload_options_method" {
  rest_api_id   = aws_api_gateway_rest_api.silent_scalper_api.id
  resource_id   = aws_api_gateway_resource.upload_resource.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# API Gateway Integration for OPTIONS (MOCK integration for CORS)
resource "aws_api_gateway_integration" "upload_options_integration" {
  rest_api_id = aws_api_gateway_rest_api.silent_scalper_api.id
  resource_id = aws_api_gateway_resource.upload_resource.id
  http_method = aws_api_gateway_method.upload_options_method.http_method
  type        = "MOCK" # MOCK integration is standard for CORS preflight
  request_templates = {
    "application/json" = "{ \"statusCode\": 200 }"
  }
}

# API Gateway Method Response for OPTIONS (CORS)
resource "aws_api_gateway_method_response" "upload_options_method_response" {
  rest_api_id = aws_api_gateway_rest_api.silent_scalper_api.id
  resource_id = aws_api_gateway_resource.upload_resource.id
  http_method = aws_api_gateway_method.upload_options_method.http_method
  status_code = "200"
  response_models = {
    "application/json" = "Empty"
  }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

# API Gateway Integration Response for OPTIONS (CORS)
resource "aws_api_gateway_integration_response" "upload_options_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.silent_scalper_api.id
  resource_id = aws_api_gateway_resource.upload_resource.id
  http_method = aws_api_gateway_method.upload_options_method.http_method
  status_code = aws_api_gateway_method_response.upload_options_method_response.status_code

  response_templates = {
    "application/json" = ""
  }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
    "method.response.header.Access-Control-Allow-Methods" = "'OPTIONS,POST'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'" # IMPORTANT: Change to your frontend domain in production
  }
}

# API Gateway Deployment
resource "aws_api_gateway_deployment" "silent_scalper_deployment" {
  rest_api_id = aws_api_gateway_rest_api.silent_scalper_api.id
  # Triggers a new deployment whenever the API definition changes
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.upload_resource.id,
      aws_api_gateway_method.upload_post_method.id,
      aws_api_gateway_integration.upload_lambda_integration.id,
      aws_api_gateway_method.upload_options_method.id,
      aws_api_gateway_integration.upload_options_integration.id,
      aws_api_gateway_method_response.upload_options_method_response.id,
      aws_api_gateway_integration_response.upload_options_integration_response.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true # Ensures new deployment is created before old one is destroyed
  }
}

# API Gateway Stage
resource "aws_api_gateway_stage" "silent_scalper_stage" {
  deployment_id = aws_api_gateway_deployment.silent_scalper_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.silent_scalper_api.id
  stage_name    = var.api_gateway_stage_name

  # Enable CloudWatch logging for API Gateway
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway_log_group.arn
    format          = jsonencode({
      requestId               = "$context.requestId"
      ip                      = "$context.identity.sourceIp"
      caller                  = "$context.identity.caller"
      user                    = "$context.identity.user"
      requestTime             = "$context.requestTime"
      httpMethod              = "$context.httpMethod"
      resourcePath            = "$context.resourcePath"
      status                  = "$context.status"
      protocol                = "$context.protocol"
      responseLength          = "$context.responseLength"
      responseLatency         = "$context.responseLatency"
      integrationLatency      = "$context.integrationLatency"
      integrationStatus       = "$context.integrationStatus"
      errorMessage            = "$context.error.message"
      validationErrorString   = "$context.error.validationErrorString"
    })
  }

  tags = {
    Project = "SilentScalper"
  }
}

# CloudWatch Log Group for API Gateway
resource "aws_cloudwatch_log_group" "api_gateway_log_group" {
  name              = "/aws/api-gateway/${aws_api_gateway_rest_api.silent_scalper_api.name}/${var.api_gateway_stage_name}"
  retention_in_days = 7 # Log retention period

  tags = {
    Project = "SilentScalper"
  }
}

# -----------------------------------------------------------------------------
# 7. CloudWatch Monitoring and SNS Alerting
# -----------------------------------------------------------------------------

# SNS Topic for error alerts
resource "aws_sns_topic" "silent_scalper_alerts" {
  name = "SilentScalperAlerts-${var.unique_id}"

  tags = {
    Project = "SilentScalper"
  }
}

# SNS Topic Subscription (Email)
resource "aws_sns_topic_subscription" "email_subscription" {
  topic_arn = aws_sns_topic.silent_scalper_alerts.arn
  protocol  = "email"
  endpoint  = var.sns_notification_email
  # You will still need to confirm this subscription via email after 'terraform apply'
}

# CloudWatch Alarm for GetPresignedUrlLambda errors
resource "aws_cloudwatch_metric_alarm" "get_presigned_url_lambda_error_alarm" {
  alarm_name          = "SilentScalper-GetPresignedUrlLambda-ErrorAlarm-${var.unique_id}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60 # 1 minute
  statistic           = "Sum"
  threshold           = 1 # Trigger if 1 or more errors in 1 minute
  treat_missing_data  = "notBreaching" # Treat missing data as not breaching

  dimensions = {
    FunctionName = aws_lambda_function.get_presigned_url_lambda.function_name
  }

  alarm_actions = [aws_sns_topic.silent_scalper_alerts.arn]
  ok_actions    = [aws_sns_topic.silent_scalper_alerts.arn] # Reset alarm status

  tags = {
    Project = "SilentScalper"
  }
}

# CloudWatch Alarm for FileProcessorLambda errors
resource "aws_cloudwatch_metric_alarm" "file_processor_lambda_error_alarm" {
  alarm_name          = "SilentScalper-FileProcessorLambda-ErrorAlarm-${var.unique_id}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60 # 1 minute
  statistic           = "Sum"
  threshold           = 1 # Trigger if 1 or more errors in 1 minute
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.file_processor_lambda.function_name
  }

  alarm_actions = [aws_sns_topic.silent_scalper_alerts.arn]
  ok_actions    = [aws_sns_topic.silent_scalper_alerts.arn]

  tags = {
    Project = "SilentScalper"
  }
}
