#!/bin/bash
set -e

# ============================================================
# Deploy Script for Node.js App on AWS ECS Fargate
# ============================================================
# Usage:
#   ./deploy.sh              # Deploy to dev (default)
#   ./deploy.sh --env prod   # Deploy to specific environment
# ============================================================

# --- Parse arguments ---
ENV="dev"
while [[ $# -gt 0 ]]; do
    case $1 in
        --env) ENV="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Configuration ---
STACK_NAME="node-app-${ENV}"
REGION="ap-southeast-1"
IMAGE_NAME="node-app"
CONTAINER_PORT=80

echo "============================================"
echo " Deploying to: ${ENV}"
echo " Stack name:   ${STACK_NAME}"
echo " Region:       ${REGION}"
echo "============================================"

# --- Step 1: Check prerequisites ---
echo ""
echo "[1/11] Checking prerequisites..."

if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI not found. Install it from https://aws.amazon.com/cli/"
    exit 1
fi

if ! command -v sam &> /dev/null; then
    echo "Error: SAM CLI not found. Install it from https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html"
    exit 1
fi

if ! command -v docker &> /dev/null; then
    echo "Error: Docker not found. Install it from https://docs.docker.com/get-docker/"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo "Error: Docker is not running. Start Docker Desktop or the Docker service."
    exit 1
fi

if ! aws sts get-caller-identity &> /dev/null; then
    echo "Error: AWS CLI is not configured. Run 'aws configure' to set up credentials."
    exit 1
fi

echo "All prerequisites met."

# --- Step 2: Create nginx.conf from template ---
echo ""
echo "[2/11] Creating nginx.conf from template..."

if [ ! -f nginx.conf ]; then
    cp nginx.conf.example nginx.conf
    echo "nginx.conf created."
else
    echo "nginx.conf already exists, skipping."
fi

# --- Step 3: Build Docker image ---
echo ""
echo "[3/11] Building Docker image..."

docker build -t ${IMAGE_NAME} .
echo "Docker image built successfully."

# --- Step 4: Build SAM template ---
echo ""
echo "[4/11] Building SAM template..."

sam build
echo "SAM build completed."

# --- Step 5: Ensure S3 deployment bucket exists ---
echo ""
echo "[5/11] Ensuring S3 deployment bucket exists..."

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
S3_BUCKET="sam-deploy-${ACCOUNT_ID}"

if ! aws s3 ls "s3://${S3_BUCKET}" &>/dev/null; then
    aws s3 mb "s3://${S3_BUCKET}" --region "${REGION}"
    echo "Created bucket: ${S3_BUCKET}"
else
    echo "Bucket already exists: ${S3_BUCKET}"
fi

# --- Step 6: Deploy CloudFormation stack ---
echo ""
echo "[6/11] Deploying CloudFormation stack..."

if [ ! -f samconfig.toml ]; then
    echo "No samconfig.toml found — running guided setup..."
    echo "Enter your API key when prompted (ApiKey parameter)."
    echo "Accept defaults for other parameters."
    echo "Stack name is pre-set to '${STACK_NAME}'."
    sam deploy --guided --stack-name "${STACK_NAME}" --s3-bucket "${S3_BUCKET}" --capabilities CAPABILITY_NAMED_IAM
else
    sam deploy --s3-bucket "${S3_BUCKET}" --capabilities CAPABILITY_NAMED_IAM
fi
echo "Stack deployment completed."

# --- Step 7: Get stack outputs ---
echo ""
echo "[7/11] Retrieving stack outputs..."

ECR_URI=$(aws cloudformation describe-stacks \
    --stack-name ${STACK_NAME} \
    --region ${REGION} \
    --query "Stacks[0].Outputs[?OutputKey=='ECRRepositoryURI'].OutputValue" \
    --output text)

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

if [ -z "$ECR_URI" ] || [ -z "$CLUSTER" ] || [ -z "$SERVICE" ]; then
    echo "Error: Failed to retrieve stack outputs."
    exit 1
fi

echo "ECR URI:  ${ECR_URI}"
echo "Cluster:  ${CLUSTER}"
echo "Service:  ${SERVICE}"

# --- Step 8: Authenticate Docker to ECR ---
echo ""
echo "[8/11] Authenticating Docker to ECR..."

aws ecr get-login-password --region ${REGION} | \
    docker login --username AWS --password-stdin ${ECR_URI}

echo "Docker authenticated to ECR."

# --- Step 9: Tag and push image to ECR ---
echo ""
echo "[9/11] Pushing image to ECR..."

docker tag ${IMAGE_NAME}:latest ${ECR_URI}:latest
docker push ${ECR_URI}:latest

echo "Image pushed to ECR."

# --- Step 10: Scale up to 1 and update ECS service ---
echo ""
echo "[10/11] Scaling service to 1 task and updating ECS service..."

# samconfig.toml deploys with DesiredCount=0 (image not in ECR yet),
# so scale to 1 now that the image has been pushed
aws ecs update-service \
    --cluster ${CLUSTER} \
    --service ${SERVICE} \
    --desired-count 1 \
    --region ${REGION} > /dev/null

aws ecs update-service \
    --cluster ${CLUSTER} \
    --service ${SERVICE} \
    --force-new-deployment \
    --region ${REGION} > /dev/null

echo "ECS service scaled to 1 and updated, new deployment in progress."

# --- Step 11: Wait for task to start and retrieve the public IP ---
# The task takes 1-2 min to start on Fargate, so poll until the public IP
# is assigned instead of only waiting 5 seconds (which often hit the fallback).
echo ""
echo "[11/11] Waiting for the task to start and retrieving the app URL..."

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
