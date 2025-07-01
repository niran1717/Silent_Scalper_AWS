import json
import os
import boto3
import uuid

# Initialize S3 client
s3_client = boto3.client('s3')

# Retrieve environment variable for the S3 input bucket name
# This variable will be set by Terraform
S3_INPUT_BUCKET_NAME = os.environ.get('S3_INPUT_BUCKET_NAME')

def lambda_handler(event, context):
    """
    Lambda function to generate an S3 pre-signed URL for file uploads.
    It expects a 'filename' in the request body.
    This function is triggered by API Gateway.
    """
    print(f"Received event: {json.dumps(event)}")

    # Ensure S3_INPUT_BUCKET_NAME is set
    if not S3_INPUT_BUCKET_NAME:
        print("Error: S3_INPUT_BUCKET_NAME environment variable is not set.")
        return {
            'statusCode': 500,
            'headers': { 'Content-Type': 'application/json' },
            'body': json.dumps({'message': 'Internal server error: S3 bucket name not configured.'})
        }

    try:
        # Parse the request body (assuming API Gateway Proxy Integration)
        # The event['body'] comes as a string, so it needs to be parsed
        body = json.loads(event['body'])
        original_filename = body.get('filename')

        if not original_filename:
            print("Error: Missing filename in request body.")
            return {
                'statusCode': 400,
                'headers': { 'Content-Type': 'application/json' },
                'body': json.dumps({'message': 'Missing filename in request body'})
            }

        # Generate a unique key for the S3 object to prevent overwrites and ensure uniqueness
        # We append a UUID to the filename.
        s3_object_key = f"{uuid.uuid4()}-{original_filename}"

        # Generate the pre-signed URL for S3 PutObject operation
        # The URL will be valid for 5 minutes (300 seconds)
        presigned_url = s3_client.generate_presigned_url(
            ClientMethod='put_object',
            Params={
                'Bucket': S3_INPUT_BUCKET_NAME,
                'Key': s3_object_key,
                # 'ContentType' can be set here if you want to enforce a specific type,
                # but for general file uploads, it's often handled by the client.
                # 'ContentType': 'application/octet-stream'
            },
            ExpiresIn=300 # URL expires in 5 minutes
        )

        print(f"Generated pre-signed URL for s3://{S3_INPUT_BUCKET_NAME}/{s3_object_key}")

        # Return the pre-signed URL and the generated file key to the client
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*', # Required for CORS to allow web clients
                'Access-Control-Allow-Headers': 'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token',
                'Access-Control-Allow-Methods': 'OPTIONS,POST' # Allow POST and preflight OPTIONS
            },
            'body': json.dumps({
                'message': 'Pre-signed URL generated successfully',
                'uploadUrl': presigned_url,
                'fileKey': s3_object_key # Return the key to reference the file later
            })
        }

    except json.JSONDecodeError:
        print("Error: Invalid JSON in request body.")
        return {
            'statusCode': 400,
            'headers': { 'Content-Type': 'application/json' },
            'body': json.dumps({'message': 'Invalid JSON in request body'})
        }
    except KeyError as e:
        print(f"Error: Missing expected key in event: {e}")
        return {
            'statusCode': 400,
            'headers': { 'Content-Type': 'application/json' },
            'body': json.dumps({'message': f'Missing expected key: {e}'})
        }
    except Exception as e:
        print(f"An unexpected error occurred: {e}")
        import traceback # Used to print full stack trace for debugging in CloudWatch
        traceback.print_exc()
        return {
            'statusCode': 500,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*', # Required for CORS
                'Access-Control-Allow-Headers': 'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token',
                'Access-Control-Allow-Methods': 'OPTIONS,POST'
            },
            'body': json.dumps({'message': 'Internal server error', 'details': str(e)})
        }
