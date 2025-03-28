"""
S3 Bucket Auto-Emptying Lambda Hook

This Lambda function is designed to be invoked by a CloudFormation Lambda Hook
during the pre-provision phase of a DELETE operation on an S3 bucket. Its purpose
is to automatically empty the S3 bucket of all objects and object versions before
CloudFormation attempts to delete the bucket itself.

The function:
1. Validates that it's being called by CloudFormation Hooks
2. Ensures it's only used for DELETE operations
3. Extracts the bucket name from the CloudFormation event
4. Deletes all objects in the bucket, including versioned objects
5. Returns success to CloudFormation to continue with bucket deletion

This enables fully automated cleanup of S3 buckets during CloudFormation stack
deletion without requiring manual intervention, even when buckets contain objects.

Security note: This Lambda has S3 permissions scoped to the AWS account it runs in,
but includes validation to ensure it can only be triggered through the
CloudFormation hook mechanism.
"""

import boto3
from botocore.config import Config
import json
import logging


CLIENT_CONFIG = Config(retries={"max_attempts": 10, "mode": "standard"})
s3_client = boto3.client("s3", config=CLIENT_CONFIG)
s3 = boto3.resource('s3')


def empty_bucket(bucket_name: str) -> dict:
    """
    Empty an S3 bucket by deleting all objects within it.

    Args:
        bucket_name: Name of the S3 bucket to empty

    Returns:
        dict: Response from the final delete_objects call
    """
    bucket = s3.Bucket(bucket_name)

    # Delete current objects (latest versions)
    delete_response = bucket.objects.delete()

    # Delete object versions if versioning is enabled
    bucket.object_versions.delete()

    return delete_response


def lambda_handler(event, context):
    print(json.dumps(event, default=str))

    # Validate that this is being called by CloudFormation Hooks
    if not event.get("hookTypeName") or not event.get("actionInvocationPoint") or not event.get("clientRequestToken"):
        error_msg = "This Lambda function can only be invoked by CloudFormation Hooks"
        logging.error(error_msg)
        return {"hookStatus": "FAILURE", "errorCode": "Unauthorized", "message": error_msg}

    # Validate the action is specifically a DELETE pre-provision operation
    if event.get("actionInvocationPoint") != "DELETE_PRE_PROVISION":
        error_msg = f"This Lambda function is only authorized for DELETE_PRE_PROVISION operations, received: {event.get('actionInvocationPoint')}"
        logging.error(error_msg)
        return {"hookStatus": "FAILURE", "errorCode": "Unauthorized", "message": error_msg, "clientRequestToken": event["clientRequestToken"]}

    try:
        bucket_name = event["requestData"]["targetModel"]["resourceProperties"]["BucketName"]
    except KeyError as err:
        logging.error(f"KeyError: {err}")
        return {"hookStatus": "FAILURE", "errorCode": "NonCompliant", "message": f"{err}", "clientRequestToken": event["clientRequestToken"]}

    response = empty_bucket(bucket_name)
    logging.warning(f"{response=}")

    return {"hookStatus": "SUCCESS", "message": "compliant", "clientRequestToken": event["clientRequestToken"]}
