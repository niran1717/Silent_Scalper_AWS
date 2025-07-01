import json
import os
import boto3
from datetime import datetime
import uuid

# Initialize AWS clients
s3_client = boto3.client('s3')
dynamodb = boto3.resource('dynamodb') # Use resource for easier table interaction

# Retrieve environment variables. These will be set by Terraform.
S3_QUARANTINE_BUCKET_NAME = os.environ.get('S3_QUARANTINE_BUCKET_NAME')
DYNAMODB_TABLE_NAME = os.environ.get('DYNAMODB_TABLE_NAME')

# Ensure environment variables are set. Critical for Lambda to function.
if not S3_QUARANTINE_BUCKET_NAME:
    raise ValueError("S3_QUARANTINE_BUCKET_NAME environment variable is not set.")
if not DYNAMODB_TABLE_NAME:
    raise ValueError("DYNAMODB_TABLE_NAME environment variable is not set.")

# Get a reference to the DynamoDB table
dynamodb_table = dynamodb.Table(DYNAMODB_TABLE_NAME)

def validate_file_content(file_content):
    """
    Simple validation logic for demonstration purposes.
    For a real application, this would be much more sophisticated:
    - Check file headers/magic numbers for actual file type (e.g., using python-magic).
    - Parse content (e.g., CSV, JSON, XML) for schema validation (e.g., using jsonschema).
    - Check for malicious content or PII (e.g., using AWS Macie or custom logic).
    """
    # Example validation: Check if file content is not empty and contains a specific keyword "job_id"
    if not file_content:
        return False, "File is empty"
    if "job_id" not in file_content.lower():
        return False, "Content missing 'job_id' keyword"
    # Add more validation rules here based on your specific job file requirements
    return True, "Valid"

def extract_metadata(file_content, s3_key):
    """
    Extracts metadata from the file content and S3 key.
    For a real application, this would parse the file (e.g., JSON, XML)
    to extract structured data relevant to the job.
    """
    job_id = "UNKNOWN" # Default JobId if not found
    try:
        # Attempt to parse file content as JSON
        data = json.loads(file_content)
        if 'job_id' in data:
            job_id = data['job_id']
        elif 'JobId' in data: # Handle alternative casing
            job_id = data['JobId']
    except json.JSONDecodeError:
        # If not valid JSON, we can try to extract from text or default
        pass
    
    # Extract original filename from S3 key (remove UUID prefix if present)
    # The s3_key format is typically "uuid-original_filename.extension"
    original_filename = s3_key.split('-', 1)[-1] if '-' in s3_key else s3_key

    # Return a dictionary of extracted metadata
    return {
        "JobId": str(job_id), # Ensure JobId is a string for DynamoDB partition key
        "OriginalFileName": original_filename,
        "S3Key": s3_key,
        "FileSize": len(file_content.encode('utf-8')), # Approximate size in bytes (UTF-8 encoded)
        "ProcessingTimestamp": datetime.now().isoformat() # ISO 8601 format for easy sorting
    }

def lambda_handler(event, context):
    """
    Lambda function triggered by S3 object creation events.
    It reads the uploaded file, validates its content, extracts metadata,
    stores the metadata in DynamoDB, and quarantines invalid files in a separate S3 bucket.
    """
    print(f"Received event: {json.dumps(event)}")

    # Extract S3 bucket and object key from the event.
    # S3 events typically come with a 'Records' array.
    if 'Records' not in event or not event['Records']:
        print("No S3 records found in the event. This Lambda expects S3 event triggers.")
        return {
            'statusCode': 400,
            'body': json.dumps({'message': 'No S3 records found in the event'})
        }

    record = event['Records'][0]
    s3_event = record['s3']
    source_bucket_name = s3_event['bucket']['name']
    s3_key = s3_event['object']['key'] # The key of the newly created object in S3

    print(f"Attempting to process file: s3://{source_bucket_name}/{s3_key}")

    file_content = "" # Initialize file_content for error handling
    try:
        # 1. Read the file content from the S3 Input bucket
        response = s3_client.get_object(Bucket=source_bucket_name, Key=s3_key)
        file_content = response['Body'].read().decode('utf-8') # Decode to string
        print(f"Successfully read file content for {s3_key}. Content length: {len(file_content)} bytes.")

        # 2. Validate file content
        is_valid, validation_message = validate_file_content(file_content)
        print(f"File validation result for {s3_key}: Valid={is_valid}, Message='{validation_message}'")

        # 3. Extract metadata from the file and S3 key
        metadata = extract_metadata(file_content, s3_key)
        metadata['ValidationStatus'] = 'VALID' if is_valid else 'INVALID'
        metadata['ValidationMessage'] = validation_message
        metadata['SourceBucket'] = source_bucket_name # Add source bucket for traceability

        # 4. Store metadata in DynamoDB
        # The JobId and Timestamp form the primary key for the DynamoDB table
        dynamodb_table.put_item(Item=metadata)
        print(f"Metadata stored in DynamoDB for JobId: {metadata['JobId']}, S3Key: {s3_key}")

        # 5. Handle invalid files: copy to quarantine bucket
        if not is_valid:
            print(f"File {s3_key} is invalid. Copying to quarantine bucket: {S3_QUARANTINE_BUCKET_NAME}")
            s3_client.copy_object(
                Bucket=S3_QUARANTINE_BUCKET_NAME,
                CopySource={'Bucket': source_bucket_name, 'Key': s3_key},
                Key=f"invalid/{s3_key}" # Store under an 'invalid/' prefix in quarantine
            )
            # Optional: Delete the original invalid file from the source bucket after copying
            # This depends on your workflow; for reprocessing, you might keep it.
            # s3_client.delete_object(Bucket=source_bucket_name, Key=s3_key)
            print(f"File {s3_key} copied to quarantine.")

        # Return a success response
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'File processed successfully',
                's3Key': s3_key,
                'isValid': is_valid,
                'validationMessage': validation_message,
                'jobId': metadata['JobId']
            })
        }

    except Exception as e:
        print(f"Error processing file {s3_key}: {e}")
        import traceback
        traceback.print_exc() # Print full stack trace to CloudWatch Logs for debugging

        # Attempt to log the failure in DynamoDB even if primary processing failed
        # This ensures you have a record of all attempts, even failed ones.
        failure_metadata = {
            "JobId": s3_key, # Use S3 key as JobId for failed processing to ensure uniqueness
            "Timestamp": datetime.now().isoformat(),
            "S3Key": s3_key,
            "ValidationStatus": "PROCESSING_FAILED",
            "ValidationMessage": str(e),
            "OriginalFileName": s3_key.split('-', 1)[-1] if '-' in s3_key else s3_key,
            "FileSize": len(file_content.encode('utf-8')) if file_content else 0, # Log size if content was read
            "SourceBucket": source_bucket_name
        }
        try:
            dynamodb_table.put_item(Item=failure_metadata)
            print(f"Logged processing failure for S3Key: {s3_key} in DynamoDB.")
        except Exception as db_e:
            print(f"CRITICAL ERROR: Failed to log processing failure to DynamoDB for {s3_key}: {db_e}")

        # Return an error response
        return {
            'statusCode': 500,
            'body': json.dumps({'message': f'Error processing file {s3_key}', 'error': str(e)})
        }
