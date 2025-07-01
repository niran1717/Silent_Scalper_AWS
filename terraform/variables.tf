# AWS Region where all resources will be deployed
variable "aws_region" {
  description = "The AWS region to deploy resources in."
  type        = string
  default     = "us-east-1" # IMPORTANT: Change this to your desired AWS region
}

# Unique identifier to append to resource names to ensure global uniqueness (especially for S3 buckets)
variable "unique_id" {
  description = "A unique identifier (e.g., your initials + random number) to append to resource names."
  type        = string
  default     = "yourinitials-1234" # IMPORTANT: CHANGE THIS TO SOMETHING UNIQUE (e.g., jsmith-4567)
}

# S3 Bucket Names
variable "s3_input_bucket_name_prefix" {
  description = "Prefix for the S3 bucket that receives input files."
  type        = string
  default     = "silent-scalper-input-files"
}

variable "s3_quarantine_bucket_name_prefix" {
  description = "Prefix for the S3 bucket that quarantines invalid files."
  type        = string
  default     = "silent-scalper-quarantine-files"
}

# DynamoDB Table Name
variable "dynamodb_table_name" {
  description = "Name of the DynamoDB table for file metadata."
  type        = string
  default     = "SilentScalperMetadata"
}

# Lambda Function Names
variable "get_presigned_url_lambda_name" {
  description = "Name for the Lambda function generating pre-signed URLs."
  type        = string
  default     = "SilentScalperGetPresignedUrlLambda"
}

variable "file_processor_lambda_name" {
  description = "Name for the Lambda function processing uploaded files."
  type        = string
  default     = "SilentScalperFileProcessorLambda"
}

# API Gateway Name and Stage
variable "api_gateway_name" {
  description = "Name for the API Gateway REST API."
  type        = string
  default     = "SilentScalperApi"
}

variable "api_gateway_stage_name" {
  description = "Name for the API Gateway deployment stage."
  type        = string
  default     = "dev" # Or 'prod'
}

# SNS Notification Email
variable "sns_notification_email" {
  description = "Email address for SNS error notifications."
  type        = string
  default     = "your-email@example.com" # IMPORTANT: Change this to your actual email address
}

# Paths to Lambda deployment packages (ZIP files)
# These paths are relative to the 'terraform/' directory
variable "get_presigned_url_lambda_zip_path" {
  description = "Path to the GetPresignedUrlLambda deployment package (ZIP file)."
  type        = string
  default     = "../lambda/get_presigned_url/lambda_function.zip"
}

variable "file_processor_lambda_zip_path" {
  description = "Path to the FileProcessorLambda deployment package (ZIP file)."
  type        = string
  default     = "../lambda/file_processor/lambda_function.zip"
}
