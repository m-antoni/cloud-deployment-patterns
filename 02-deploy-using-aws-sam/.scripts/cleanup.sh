#!/bin/bash
set -e

# ============================================================
# Cleanup Script for Node.js App on AWS ECS Fargate
# ============================================================
# Usage:
#   ./cleanup.sh              # Delete dev environment (default)
#   ./cleanup.sh --env prod   # Delete specific environment
#   ./cleanup.sh --env all    # Delete all environments
# ============================================================

# --- Parse arguments ---
ENV="dev"
while [[ $# -gt 0 ]]; do
    case $1 in
        --env) ENV="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

REGION="ap-southeast-1"

# --- Delete a single environment ---
delete_env() {
    local TARGET_ENV=$1
    local STACK_NAME="node-app-${TARGET_ENV}"

    echo ""
    echo "--------------------------------------------"
    echo " Deleting: ${TARGET_ENV}"
    echo " Stack:    ${STACK_NAME}"
    echo "--------------------------------------------"

    sam delete --stack-name ${STACK_NAME} --region ${REGION} --no-prompts
    echo "Stack '${STACK_NAME}' deleted."
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

    read -p "Are you sure? (y/N): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "Cleanup cancelled."
        exit 0
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

    read -p "Are you sure? (y/N): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "Cleanup cancelled."
        exit 0
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
