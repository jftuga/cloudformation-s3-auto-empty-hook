#!/bin/bash
# -----------------------------------------------------------------------------
# CloudFormation Deployment Script
# -----------------------------------------------------------------------------
# Purpose:
#   Deploys two CloudFormation stacks:
#   1. Lambda hook infrastructure (permanent, deployed once)
#   2. S3 bucket resources (can be deployed to multiple environments)
#
# Usage:
#   ./deploy-stacks.sh [--hook-only] [--bucket-only] [--profile <profile>] [--region <region>]
#
# Arguments:
#   --hook-only     Deploy only the Lambda hook infrastructure
#   --bucket-only   Deploy only the S3 bucket resources
#   --profile       AWS profile to use (overrides .env)
#   --region        AWS region to deploy to (overrides .env)
#   --help          Display this help message
# -----------------------------------------------------------------------------

set -euo pipefail

# Source environment variables
if [[ -f .env ]]; then
    source .env
else
    echo "Error: .env file not found"
    exit 1
fi

# Default flags
DEPLOY_HOOK=true
DEPLOY_BUCKET=true

# Process command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --hook-only)
            DEPLOY_HOOK=true
            DEPLOY_BUCKET=false
            shift
            ;;
        --bucket-only)
            DEPLOY_HOOK=false
            DEPLOY_BUCKET=true
            shift
            ;;
        --profile)
            MY_AWS_PROFILE="$2"
            shift 2
            ;;
        --region)
            DEPLOYER_REGION="$2"
            shift 2
            ;;
        --help)
            echo "Usage: ./deploy-stacks.sh [--hook-only] [--bucket-only] [--profile <profile>] [--region <region>] [--help]"
            echo ""
            echo "Options:"
            echo "  --hook-only     Deploy only the Lambda hook infrastructure"
            echo "  --bucket-only   Deploy only the S3 bucket resources"
            echo "  --profile       AWS profile to use (overrides .env)"
            echo "  --region        AWS region to deploy to (overrides .env)"
            echo "  --help          Display this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Disable telemetry
export SAM_CLI_TELEMETRY=0

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is required but not installed. Get it from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

# Get AWS account ID using the standard AWS CLI command
AWS_ACC_ID="$(aws sts get-caller-identity --output text --query Account)"
if [[ -z "${AWS_ACC_ID}" ]]; then
    echo "Error: Failed to get AWS account ID"
    exit 1
fi
export AWS_ACC_ID

# Set other environment variables
export MY_AWS_PROFILE
export DEPLOYER_REGION
export BUCKET_NAME="${BUCKET_NAME_PREFIX}-${AWS_ACC_ID}"
NAME_SUFFIX=$(echo "-${USER}" | cut -d. -f1)
export NAME_SUFFIX
export CFN_HOOK_INVOKER_ROLE_NAME
export CFN_HOOK_LAMBDA_NAME
export HOOK_TARGET_ACTION
export HOOK_TARGET_NAME

# Run code linting
echo "Running code linting..."
if ! ruff check src/; then
    echo "Error: Code linting failed"
    exit 1
fi

###############################
# Function to deploy the Lambda hook infrastructure stack
###############################
function deploy_hook() {
    echo "Deploying Lambda hook infrastructure..."

    export MY_STACK_NAME="lambda-hook-test${NAME_SUFFIX}"
    STACK_SHORT_NAME=$(echo "${MY_STACK_NAME}" | tr -d '-' | tr -d '_' | tr -d '.' | cut -c 1-64)
    export STACK_SHORT_NAME

    # Clean build directory
    echo "Cleaning build directory..."
    command rm -rf ./.aws-sam/

    # Build SAM template
    echo "Building SAM template..."
    if ! time sam build -p -c -t lambda-hook-infrastructure.yaml; then
        echo "Error: SAM build failed for hook infrastructure"
        return 1
    fi

    # Deploy SAM template
    echo "Deploying hook infrastructure stack..."
    if ! time sam deploy --profile "${MY_AWS_PROFILE}" \
        --region "${DEPLOYER_REGION}" \
        --stack-name "${MY_STACK_NAME}" \
        --capabilities CAPABILITY_NAMED_IAM \
        --s3-bucket "artifacts-${AWS_ACC_ID}-${DEPLOYER_REGION}" \
        --s3-prefix "${MY_STACK_NAME}" \
        --no-fail-on-empty-changeset \
        --on-failure DO_NOTHING \
        --parameter-overrides \
            DeployerRegion="${DEPLOYER_REGION}" \
            CfnHookInvokerRoleName=${CFN_HOOK_INVOKER_ROLE_NAME} \
            CfnHookLambdaName=${CFN_HOOK_LAMBDA_NAME} \
        --tags "owner=${USER}" "environment=${DEPLOYMENT_ENVIRONMENT}"; then

        echo "Error: SAM deploy failed for hook infrastructure"
        return 1
    fi

    echo "Hook infrastructure deployment completed successfully!"
    return 0
}

###############################
# Function to deploy the S3 bucket resources stack
###############################
function deploy_bucket() {
    echo "Deploying S3 bucket resources..."

    export MY_STACK_NAME="bucket-${AWS_ACC_ID}-${NAME_SUFFIX}"
    STACK_SHORT_NAME=$(echo "${MY_STACK_NAME}" | tr -d '-' | tr -d '_' | tr -d '.' | cut -c 1-64)
    export STACK_SHORT_NAME

    # Clean build directory
    echo "Cleaning build directory..."
    command rm -rf ./.aws-sam/

    # Build SAM template
    echo "Building SAM template..."
    if ! time sam build -p -c -t s3-bucket-resources.yaml; then
        echo "Error: SAM build failed for bucket resources"
        return 1
    fi

    # Deploy SAM template
    echo "Deploying bucket resources stack..."
    if ! time sam deploy --profile "${MY_AWS_PROFILE}" \
        --region "${DEPLOYER_REGION}" \
        --stack-name "${MY_STACK_NAME}" \
        --capabilities CAPABILITY_NAMED_IAM \
        --s3-bucket "artifacts-${AWS_ACC_ID}-${DEPLOYER_REGION}" \
        --s3-prefix "${MY_STACK_NAME}" \
        --no-fail-on-empty-changeset \
        --on-failure DO_NOTHING \
        --parameter-overrides \
            BucketName="${BUCKET_NAME}" \
            StackShortName="${STACK_SHORT_NAME}" \
            CfnHookInvokerRoleName=${CFN_HOOK_INVOKER_ROLE_NAME} \
            CfnHookLambdaName=${CFN_HOOK_LAMBDA_NAME} \
            HookTargetAction=${HOOK_TARGET_ACTION} \
            HookTargetName=${HOOK_TARGET_NAME} \
        --tags "owner=${USER}" "environment=${DEPLOYMENT_ENVIRONMENT}"; then

        echo "Error: SAM deploy failed for bucket resources"
        return 1
    fi

    echo "Bucket resources deployment completed successfully!"
    return 0
}

###############################
# Main deployment process
###############################

# Track overall success
DEPLOY_SUCCESS=true

# Deploy hook infrastructure if requested
if [[ "${DEPLOY_HOOK}" == "true" ]]; then
    if ! deploy_hook; then
        DEPLOY_SUCCESS=false
        echo "Hook infrastructure deployment failed!"
    fi
fi

# Deploy bucket resources if requested
if [[ "${DEPLOY_BUCKET}" == "true" ]]; then
    # Continue with bucket deployment even if hook failed
    set +e
    if ! deploy_bucket; then
        DEPLOY_SUCCESS=false
        echo "Bucket resources deployment failed!"
    fi
    set -e
fi

# Final status report
if [[ "${DEPLOY_SUCCESS}" == "true" ]]; then
    echo "All requested deployments completed successfully!"
    exit 0
else
    echo "One or more deployments failed. Check the logs for details."
    exit 1
fi