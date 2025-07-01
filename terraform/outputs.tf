# Output the API Gateway Invoke URL for the /upload endpoint
output "api_gateway_upload_url" {
  description = "The Invoke URL for the API Gateway /upload endpoint."
  value       = "${aws_api_gateway_deployment.silent_scalper_deployment.invoke_url}/${var.api_gateway_stage_name}/upload"
}

# Output the S3 Input Bucket Name
output "s3_input_bucket_name" {
  description = "The name of the S3 bucket where files are uploaded."
  value       = aws_s3_bucket.input_bucket.bucket
}

# Output the S3 Quarantine Bucket Name
output "s3_quarantine_bucket_name" {
  description = "The name of the S3 bucket where invalid files are quarantined."
  value       = aws_s3_bucket.quarantine_bucket.bucket
}

# Output the DynamoDB Table Name
output "dynamodb_table_name" {
  description = "The name of the DynamoDB table storing file metadata."
  value       = aws_dynamodb_table.metadata_table.name
}

# Output the SNS Topic ARN (for confirmation)
output "sns_topic_arn" {
  description = "The ARN of the SNS topic for error alerts."
  value       = aws_sns_topic.silent_scalper_alerts.arn
}
