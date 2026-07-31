#!/bin/bash
set -e

# ============================================================
# Deploy Script for Node.js App on AWS ECS Fargate
# ============================================================
# Usage:
#   ./deploy.sh                             # Deploy to dev (default)
#   ./deploy.sh --env prod                  # Deploy to specific environment
#   ./deploy.sh --tag <image-tag>           # Pin a specific image tag (git SHA)
# ============================================================
# Builds the image, pushes it to ECR (pinned tag + latest), then hands off to
# rollback.sh which deploys the pinned tag via CloudFormation and reverts to
# the previous tag automatically if the deployment fails.
# ============================================================

# --- Parse arguments ---
ENV="dev"
TAG=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --env) ENV="$2"; shift 2 ;;
        --tag) TAG="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Default the pinned tag to the current git SHA, else a timestamp
if [ -z "$TAG" ]; then
    TAG=$(git rev-parse --short HEAD 2>/dev/null || echo "$(date +%Y%m%d%H%M%S)")
fi

# --- Configuration ---
STACK_NAME="node-app-${ENV}"
REGION="ap-southeast-1"
IMAGE_NAME="node-app"
CONTAINER_PORT=80

echo "============================================"
echo " Deploying to: ${ENV}"
echo " Stack name:   ${STACK_NAME}"
echo " Region:       ${REGION}"
echo " Image tag:    ${TAG}"
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

# --- Step 6: Ensure the CloudFormation stack exists ---
# The ECR repository must exist before we can push the image. On the first
# deploy the stack (which owns the ECR repo) is created here; later deploys
# just push the image and let rollback.sh apply the template + pinned tag.
echo ""
echo "[6/11] Ensuring CloudFormation stack '${STACK_NAME}' exists..."

if aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${REGION} &>/dev/null; then
    echo "Stack already exists, skipping creation."
else
    echo "Stack not found -- creating it now..."
    if [ ! -f samconfig.toml ]; then
        echo "No samconfig.toml found -- running guided setup..."
        echo "Enter your API key when prompted (ApiKey parameter)."
        echo "Accept defaults for other parameters."
        echo "Stack name is pre-set to '${STACK_NAME}'."
        sam deploy --guided --stack-name "${STACK_NAME}" --s3-bucket "${S3_BUCKET}" --capabilities CAPABILITY_NAMED_IAM
    else
        sam deploy --s3-bucket "${S3_BUCKET}" --capabilities CAPABILITY_NAMED_IAM
    fi
    echo "Stack created."
fi

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

# --- Step 9: Tag and push image to ECR (pinned tag + latest) ---
echo ""
echo "[9/11] Pushing image to ECR..."

docker tag ${IMAGE_NAME}:latest ${ECR_URI}:latest
docker tag ${IMAGE_NAME}:latest ${ECR_URI}:${TAG}
docker push ${ECR_URI}:latest
docker push ${ECR_URI}:${TAG}

echo "Image pushed to ECR (latest + ${TAG})."

# --- Step 10: Scale up to 1 (first deploy deploys with DesiredCount=0) ---
echo ""
echo "[10/11] Scaling service to 1 task..."

aws ecs update-service \
    --cluster ${CLUSTER} \
    --service ${SERVICE} \
    --desired-count 1 \
    --region ${REGION} > /dev/null

echo "Service scaled to 1 task."

# --- Step 11: Deploy pinned tag with rollback protection ---
# rollback.sh runs the CloudFormation deploy with the pinned ImageTag,
# waits for the ECS deployment to become healthy, and reverts to the
# previous tag on failure.
echo ""
echo "[11/11] Deploying pinned image tag '${TAG}' with rollback protection..."

bash .scripts/rollback.sh --env ${ENV} --tag ${TAG}
