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
echo "[1/10] Checking prerequisites..."

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
echo "[2/10] Creating nginx.conf from template..."

if [ ! -f nginx.conf ]; then
    cp nginx.conf.example nginx.conf
    echo "nginx.conf created."
else
    echo "nginx.conf already exists, skipping."
fi

# --- Step 3: Build Docker image ---
echo ""
echo "[3/10] Building Docker image..."

docker build -t ${IMAGE_NAME} .
echo "Docker image built successfully."

# --- Step 4: Build SAM template ---
echo ""
echo "[4/10] Building SAM template..."

sam build
echo "SAM build completed."

# --- Step 5: Deploy CloudFormation stack ---
echo ""
echo "[5/10] Deploying CloudFormation stack..."

sam deploy
echo "Stack deployment completed."

# --- Step 6: Get stack outputs ---
echo ""
echo "[6/10] Retrieving stack outputs..."

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

# --- Step 7: Authenticate Docker to ECR ---
echo ""
echo "[7/10] Authenticating Docker to ECR..."

aws ecr get-login-password --region ${REGION} | \
    docker login --username AWS --password-stdin ${ECR_URI}

echo "Docker authenticated to ECR."

# --- Step 8: Tag and push image to ECR ---
echo ""
echo "[8/10] Pushing image to ECR..."

docker tag ${IMAGE_NAME}:latest ${ECR_URI}:latest
docker push ${ECR_URI}:latest

echo "Image pushed to ECR."

# --- Step 9: Update ECS service ---
echo ""
echo "[9/10] Updating ECS service..."

aws ecs update-service \
    --cluster ${CLUSTER} \
    --service ${SERVICE} \
    --force-new-deployment \
    --region ${REGION} > /dev/null

echo "ECS service updated, new deployment in progress."

# --- Step 10: Get app URL ---
echo ""
echo "[10/10] Retrieving app URL..."

sleep 5

TASK_ARN=$(aws ecs list-tasks \
    --cluster ${CLUSTER} \
    --service-name ${SERVICE} \
    --region ${REGION} \
    --query "taskArns[0]" \
    --output text)

if [ -n "$TASK_ARN" ] && [ "$TASK_ARN" != "None" ]; then
    PUBLIC_IP=$(aws ecs describe-tasks \
        --cluster ${CLUSTER} \
        --tasks ${TASK_ARN} \
        --region ${REGION} \
        --query "tasks[0].attachments[0].details[?name=='privateIPv4Address'].value" \
        --output text)

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
    echo " Note: Task is still starting up."
    echo " Check the ECS console for the public IP."
    echo ""
fi
