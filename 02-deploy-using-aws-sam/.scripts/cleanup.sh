#!/bin/bash
set -e

# ============================================================
# Cleanup Script for Node.js App on AWS ECS Fargate
# ============================================================
# Usage:
#   ./cleanup.sh              # Delete dev environment (default)
#   ./cleanup.sh --env prod   # Delete specific environment
#   ./cleanup.sh --env all    # Delete all environments
#   ./cleanup.sh --yes        # Skip confirmation prompt (for CI)
# ============================================================

# --- Parse arguments ---
ENV="dev"
YES=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --env) ENV="$2"; shift 2 ;;
        -y|--yes) YES=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

REGION="ap-southeast-1"

# --- Delete a single environment ---
delete_env() {
    local TARGET_ENV=$1
    local STACK_NAME="node-app-${TARGET_ENV}"
    local ECR_REPO="${TARGET_ENV}-node-app"

    echo ""
    echo "--------------------------------------------"
    echo " Deleting: ${TARGET_ENV}"
    echo " Stack:    ${STACK_NAME}"
    echo "--------------------------------------------"

    # Try to delete the stack
    sam delete --stack-name ${STACK_NAME} --region ${REGION} --no-prompts || true

    # Check if stack deletion failed (ECR might still have images)
    STACK_STATUS=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${REGION} --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "NOT_FOUND")

    if [ "$STACK_STATUS" == "DELETE_FAILED" ]; then
        echo "Stack deletion failed — ECR repository still contains images."
        echo "Force deleting ECR repository '${ECR_REPO}'..."

        aws ecr delete-repository --repository-name ${ECR_REPO} --region ${REGION} --force || true

        echo "Retrying stack deletion..."
        aws cloudformation delete-stack --stack-name ${STACK_NAME} --region ${REGION}

        echo "Waiting for stack to be deleted..."
        aws cloudformation wait stack-delete-complete --stack-name ${STACK_NAME} --region ${REGION} 2>/dev/null || true
    fi

    echo "Stack '${STACK_NAME}' deleted."

    # Delete the custom S3 deployment bucket
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    S3_BUCKET="sam-deploy-${ACCOUNT_ID}"
    if aws s3 ls "s3://${S3_BUCKET}" &>/dev/null; then
        aws s3 rb "s3://${S3_BUCKET}" --force
        echo "S3 bucket '${S3_BUCKET}' deleted."
    fi
}

# --- Handle --env all ---
if [ "$ENV" == "all" ]; then
    ENVIRONMENTS=("dev" "staging" "prod")

    echo "============================================"
    echo " Deleting ALL environments"
    echo " Environments: ${ENVIRONMENTS[*]}"
    echo " Region:       ${REGION}"
    echo "============================================"
    echo ""
    echo "This will delete ALL resources for dev, staging, and prod."
    echo ""

    if [ "$YES" != "true" ]; then
        read -p "Are you sure? (y/N): " CONFIRM
        if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
            echo "Cleanup cancelled."
            exit 0
        fi
    fi

    for TARGET_ENV in "${ENVIRONMENTS[@]}"; do
        delete_env ${TARGET_ENV}
    done

    echo ""
    echo "[Final] Removing local build artifacts..."

    if [ -d ".aws-sam" ]; then
        rm -rf .aws-sam/
        echo ".aws-sam/ removed."
    else
        echo "No .aws-sam/ directory found, skipping."
    fi

    echo ""
    echo "============================================"
    echo " Cleanup Complete!"
    echo "============================================"
    echo ""
    echo " All environments (dev, staging, prod) have been deleted."
    echo ""

# --- Handle single environment ---
else
    STACK_NAME="node-app-${ENV}"

    echo "============================================"
    echo " Deleting environment: ${ENV}"
    echo " Stack name:           ${STACK_NAME}"
    echo " Region:               ${REGION}"
    echo "============================================"
    echo ""
    echo "This will delete ALL resources for the '${ENV}' environment:"
    echo "  - ECS service and cluster"
    echo "  - Task definition"
    echo "  - ECR repository"
    echo "  - VPC and networking resources"
    echo "  - IAM role"
    echo "  - Secrets Manager secrets"
    echo "  - CloudWatch log group"
    echo ""

    if [ "$YES" != "true" ]; then
        read -p "Are you sure? (y/N): " CONFIRM
        if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
            echo "Cleanup cancelled."
            exit 0
        fi
    fi

    delete_env ${ENV}

    echo ""
    echo "[2/2] Removing local build artifacts..."

    if [ -d ".aws-sam" ]; then
        rm -rf .aws-sam/
        echo ".aws-sam/ removed."
    else
        echo "No .aws-sam/ directory found, skipping."
    fi

    echo ""
    echo "============================================"
    echo " Cleanup Complete!"
    echo "============================================"
    echo ""
    echo " All resources for '${ENV}' have been deleted."
    echo ""
fi
