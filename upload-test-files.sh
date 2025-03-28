#!/bin/bash
# -----------------------------------------------------------------------------
# S3 Test File Uploader
# -----------------------------------------------------------------------------
# Purpose:
#   Creates and uploads a test file to an S3 bucket, including multiple versions
#   of the same file to demonstrate versioning functionality. This script is
#   useful for testing the S3 bucket emptying hook by creating both regular
#   objects and multiple versions of the same object.
#
# Usage:
#   ./uploader.sh [--bucket <bucket-name>] [--iterations <count>]
#
# Arguments:
#   --bucket      Specify S3 bucket name (overrides auto-detection)
#   --iterations  Number of versions to create (default: 3)
#   --help        Display this help message
# -----------------------------------------------------------------------------

set -euo pipefail

# Default values
ITERATIONS=3
BUCKET_NAME=""

# Process command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --bucket)
            BUCKET_NAME="$2"
            shift 2
            ;;
        --iterations)
            ITERATIONS="$2"
            if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]]; then
                echo "Error: iterations must be a positive number"
                exit 1
            fi
            shift 2
            ;;
        --help)
            echo "Usage: ./uploader.sh [--bucket <bucket-name>] [--iterations <count>]"
            echo ""
            echo "Options:"
            echo "  --bucket      Specify S3 bucket name (overrides auto-detection)"
            echo "  --iterations  Number of versions to create (default: 3)"
            echo "  --help        Display this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Create unique filename based on current timestamp
FNAME=$(date +"%H.%M.%S.txt")
echo "Creating test file: ${FNAME}"

# Auto-detect bucket name if not specified
if [[ -z "${BUCKET_NAME}" ]]; then
    # Check if aws CLI is installed
    if ! command -v aws &> /dev/null; then
        echo "Error: AWS CLI is required but not installed. Get it from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        exit 1
    fi

    # Get AWS account ID using aws sts
    AWS_ACC_ID="$(aws sts get-caller-identity --output text --query Account)"
    if [[ -z "${AWS_ACC_ID}" ]]; then
        echo "Error: Failed to get AWS account ID"
        exit 1
    fi

    BUCKET_NAME="test-bucket-${AWS_ACC_ID}"
fi

echo "Target S3 bucket: ${BUCKET_NAME}"

# Check if bucket exists
if ! aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
    echo "Error: Bucket '${BUCKET_NAME}' does not exist or you don't have access to it"
    exit 1
fi

# Remove file if it already exists
command rm -f "${FNAME}"
touch "${FNAME}"

# Upload multiple versions of the file
for i in $(seq 1 ${ITERATIONS})
do
    echo "Run $i of ${ITERATIONS}"
    echo "Testing the uploader script (version $i) - $(date)" >> "${FNAME}"

    if ! aws s3 cp "${FNAME}" "s3://${BUCKET_NAME}"; then
        echo "Error: Failed to upload file to S3"
        command rm -f "${FNAME}"
        exit 1
    fi

    echo "Successfully uploaded version $i"

    # Short pause between uploads to ensure distinct versions
    if [[ $i -lt ${ITERATIONS} ]]; then
        sleep 0.5
    fi
done

# Clean up local file
command rm -f "${FNAME}"

echo "Upload complete! Created ${ITERATIONS} versions of ${FNAME} in bucket ${BUCKET_NAME}"
echo "To verify versioning, run: aws s3api list-object-versions --bucket ${BUCKET_NAME} --prefix ${FNAME}"