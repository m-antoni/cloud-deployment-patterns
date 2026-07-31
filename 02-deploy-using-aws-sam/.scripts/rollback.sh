#!/bin/bash
set -e

# ============================================================
# Rollback / Pinned Deploy Script for Node.js App on AWS ECS Fargate
# ============================================================
# Deploys a pinned image tag (e.g. a git SHA) through CloudFormation and
# automatically reverts the service to the previously deployed tag when the
# new deployment never becomes healthy (rollback on failure).
#
# Usage:
#   ./rollback.sh --env dev --tag <image-tag>            # auto: revert on failure
#   ./rollback.sh --env dev --tag <image-tag> --manual    # manual: no auto-revert
# ============================================================

# --- Parse arguments ---
ENV="dev"
TAG=""
MANUAL=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --env) ENV="$2"; shift 2 ;;
        --tag) TAG="$2"; shift 2 ;;
        --manual) MANUAL=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$TAG" ]; then
    echo "Error: --tag is required (e.g. --tag <git-sha> or --tag latest)"
    exit 1
fi

STACK_NAME="node-app-${ENV}"
REGION="ap-southeast-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
S3_BUCKET="sam-deploy-${ACCOUNT_ID}"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ENV}-node-app"

echo "============================================"
echo " Pinned deploy/rollback to: ${ENV}"
echo " Image tag:  ${TAG}"
echo " Stack name: ${STACK_NAME}"
echo " Region:     ${REGION}"
echo "============================================"

# --- Step 1: Get stack outputs ---
echo ""
echo "[1/5] Retrieving stack outputs..."

CLUSTER=$(aws cloudformation describe-stacks \
    --stack-name ${STACK_NAME} \
    --region ${REGION} \
    --query "Stacks[0].Outputs[?OutputKey=='ECSClusterName'].OutputValue" \
    --output text)

SERVICE=$(aws cloudformation describe-stacks \
    --stack-name ${STACK_NAME} \
    --region ${REGION} \
    --query "Stacks[0].Outputs[?OutputKey=='ECSServiceName'].OutputValue" \
    --output text)

if [ -z "$CLUSTER" ] || [ -z "$SERVICE" ] || [ "$CLUSTER" == "None" ] || [ "$SERVICE" == "None" ]; then
    echo "Error: Failed to retrieve stack outputs. Is the stack '${STACK_NAME}' deployed?"
    exit 1
fi

echo "Cluster:  ${CLUSTER}"
echo "Service:  ${SERVICE}"

# --- Step 2: Capture the currently deployed image tag (rollback target) ---
# Auto mode only: remember the tag the service runs NOW so we can revert to it
# if the new deployment fails. Manual mode skips this - you picked the target.
echo ""
echo "[2/5] Capturing currently deployed tag..."

PREV_TAG=""
if [ "$MANUAL" != "true" ]; then
    TASK_DEF_ARN=$(aws ecs describe-services \
        --cluster ${CLUSTER} \
        --services ${SERVICE} \
        --region ${REGION} \
        --query "services[0].taskDefinition" \
        --output text 2>/dev/null) || true

    if [ -n "$TASK_DEF_ARN" ] && [ "$TASK_DEF_ARN" != "None" ]; then
        CURRENT_IMAGE=$(aws ecs describe-task-definition \
            --task-definition ${TASK_DEF_ARN} \
            --region ${REGION} \
            --query "taskDefinition.containerDefinitions[0].image" \
            --output text 2>/dev/null) || true
        PREV_TAG="${CURRENT_IMAGE##*:}"
    fi

    if [ -n "$PREV_TAG" ] && [ "$PREV_TAG" != "$TAG" ]; then
        echo "Previous deployed tag: ${PREV_TAG}"
    else
        PREV_TAG=""
        echo "No previous tag to roll back to (first deploy or same tag)."
    fi
fi

# --- Step 3: Deploy the pinned tag via CloudFormation ---
# Changing ImageTag makes CloudFormation register a new task definition
# revision (pinned image) and update the ECS service.
echo ""
echo "[3/5] Deploying stack with ImageTag=${TAG}..."

sam deploy \
    --stack-name ${STACK_NAME} \
    --region ${REGION} \
    --s3-bucket ${S3_BUCKET} \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides "Environment=${ENV}" "ImageTag=${TAG}" \
    --no-confirm-changeset \
    --no-fail-on-empty-changeset

echo "Stack deployment completed."

# --- Step 4: Wait for the ECS service deployment to become stable ---
# A broken image keeps the deployment stuck (tasks fail health checks), so
# watch rolloutState until it reports COMPLETED or FAILED (timeout ~20 min).
echo ""
echo "[4/5] Waiting for the ECS service deployment to complete..."

DEPLOY_OK=false
for i in $(seq 1 60); do
    ROLLOUT=$(aws ecs describe-services \
        --cluster ${CLUSTER} \
        --services ${SERVICE} \
        --region ${REGION} \
        --query "services[0].deployments[0].rolloutState" \
        --output text 2>/dev/null) || true

    echo "  Deployment status: ${ROLLOUT} (${i}/60)"

    if [ "${ROLLOUT}" == "COMPLETED" ]; then
        DEPLOY_OK=true
        break
    fi

    if [ "${ROLLOUT}" == "FAILED" ]; then
        break
    fi

    sleep 20
done

if [ "${DEPLOY_OK}" != "true" ]; then
    echo ""
    echo "ERROR: Deployment of tag '${TAG}' did not complete successfully."

    if [ -n "${PREV_TAG}" ]; then
        echo "[ROLLBACK] Reverting to previous tag: ${PREV_TAG}..."
        sam deploy \
            --stack-name ${STACK_NAME} \
            --region ${REGION} \
            --s3-bucket ${S3_BUCKET} \
            --capabilities CAPABILITY_NAMED_IAM \
            --parameter-overrides "Environment=${ENV}" "ImageTag=${PREV_TAG}" \
            --no-confirm-changeset \
            --no-fail-on-empty-changeset
        aws ecs wait services-stable --cluster ${CLUSTER} --services ${SERVICE} --region ${REGION} || true
        echo "[ROLLBACK] Reverted to '${PREV_TAG}'."
    else
        echo "[ROLLBACK] No previous tag available - cannot roll back."
    fi

    echo ""
    echo "============================================"
    echo " Deployment FAILED!"
    echo "============================================"
    echo ""
    exit 1
fi

# --- Step 5: Retrieve the app URL ---
# The task takes 1-2 min to start on Fargate, so poll until the public IP
# is assigned instead of only waiting a few seconds.
echo ""
echo "[5/5] Waiting for the task to start and retrieving the app URL..."

PUBLIC_IP=""
for i in $(seq 1 15); do
    TASK_ARN=$(aws ecs list-tasks \
        --cluster ${CLUSTER} \
        --service-name ${SERVICE} \
        --region ${REGION} \
        --query "taskArns[0]" \
        --output text 2>/dev/null) || true

    if [ -n "$TASK_ARN" ] && [ "$TASK_ARN" != "None" ]; then
        ENI_ID=$(aws ecs describe-tasks \
            --cluster ${CLUSTER} \
            --tasks ${TASK_ARN} \
            --region ${REGION} \
            --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" \
            --output text 2>/dev/null) || true

        if [ -n "$ENI_ID" ] && [ "$ENI_ID" != "None" ]; then
            PUBLIC_IP=$(aws ec2 describe-network-interfaces \
                --network-interface-ids ${ENI_ID} \
                --region ${REGION} \
                --query "NetworkInterfaces[0].Association.PublicIp" \
                --output text 2>/dev/null) || true
        fi
    fi

    if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "None" ]; then
        break
    fi

    echo "  Task still starting up... (${i}/15)"
    sleep 10
done

if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "None" ]; then
    echo ""
    echo "============================================"
    echo " Deployment Complete!"
    echo "============================================"
    echo ""
    echo " App URL: http://${PUBLIC_IP}"
    echo " Weather: http://${PUBLIC_IP}/weather?q=manila"
    echo ""
else
    echo ""
    echo "============================================"
    echo " Deployment Complete!"
    echo "============================================"
    echo ""
    echo " Note: Could not retrieve the public IP yet."
    echo " Check the ECS console for the task's public IP."
    echo ""
fi
