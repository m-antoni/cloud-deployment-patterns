param(
    [string]$Env = "dev",
    [string]$Tag = ""
)

$ErrorActionPreference = "Stop"

# ============================================================
# Deploy Script for Node.js App on AWS ECS Fargate
# ============================================================
# Usage:
#   .\deploy.ps1                          # Deploy to dev (default)
#   .\deploy.ps1 -Env prod                # Deploy to specific environment
#   .\deploy.ps1 -Tag <image-tag>         # Pin a specific image tag (git SHA)
# ============================================================
# Builds the image, pushes it to ECR (pinned tag + latest), then hands off to
# rollback.ps1 which deploys the pinned tag via CloudFormation and reverts to
# the previous tag automatically if the deployment fails.
# ============================================================

# Default the pinned tag to the current git SHA, else a timestamp
if (-not $Tag) {
    $Tag = git rev-parse --short HEAD 2>$null
    if (-not $Tag) {
        $Tag = Get-Date -Format "yyyyMMddHHmmss"
    }
}

# --- Configuration ---
$STACK_NAME = "node-app-$Env"
$REGION = "ap-southeast-1"
$IMAGE_NAME = "node-app"

Write-Host "============================================"
Write-Host " Deploying to: $Env"
Write-Host " Stack name:   $STACK_NAME"
Write-Host " Region:       $REGION"
Write-Host " Image tag:    $Tag"
Write-Host "============================================"

# --- Step 1: Check prerequisites ---
Write-Host ""
Write-Host "[1/11] Checking prerequisites..."

if (-not (Get-Command "aws" -ErrorAction SilentlyContinue)) {
    Write-Host "Error: AWS CLI not found. Install it from https://aws.amazon.com/cli/"
    exit 1
}

if (-not (Get-Command "sam" -ErrorAction SilentlyContinue)) {
    Write-Host "Error: SAM CLI not found. Install it from https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html"
    exit 1
}

if (-not (Get-Command "docker" -ErrorAction SilentlyContinue)) {
    Write-Host "Error: Docker not found. Install it from https://docs.docker.com/get-docker/"
    exit 1
}

# 2>&1 merges stderr into the output stream (2>$null would throw under
# $ErrorActionPreference = "Stop" in PowerShell 5.1 when Docker is not running)
$DOCKER_INFO = docker info 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or -not ($DOCKER_INFO | Select-String "Server Version")) {
    Write-Host "Error: Docker is not running. Start Docker Desktop or the Docker service."
    exit 1
}

try {
    aws sts get-caller-identity 2>$null | Out-Null
} catch {
    Write-Host "Error: AWS CLI is not configured. Run 'aws configure' to set up credentials."
    exit 1
}

Write-Host "All prerequisites met."

# --- Step 2: Create nginx.conf from template ---
Write-Host ""
Write-Host "[2/11] Creating nginx.conf from template..."

if (-not (Test-Path "nginx.conf")) {
    Copy-Item "nginx.conf.example" "nginx.conf"
    Write-Host "nginx.conf created."
} else {
    Write-Host "nginx.conf already exists, skipping."
}

# --- Step 3: Build Docker image ---
Write-Host ""
Write-Host "[3/11] Building Docker image..."

docker build -t $IMAGE_NAME .
Write-Host "Docker image built successfully."

# --- Step 4: Build SAM template ---
Write-Host ""
Write-Host "[4/11] Building SAM template..."

sam build
Write-Host "SAM build completed."

# --- Step 5: Ensure S3 deployment bucket exists ---
Write-Host ""
Write-Host "[5/11] Ensuring S3 deployment bucket exists..."

$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
$S3_BUCKET = "sam-deploy-$ACCOUNT_ID"

$null = aws s3 mb "s3://$S3_BUCKET" --region $REGION 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "Created bucket: $S3_BUCKET"
} else {
    Write-Host "Bucket already exists: $S3_BUCKET"
}

# --- Step 6: Ensure the CloudFormation stack exists ---
Write-Host ""
Write-Host "[6/11] Ensuring CloudFormation stack '$STACK_NAME' exists..."

$null = aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "Stack already exists, skipping creation."
} else {
    Write-Host "Stack not found -- creating it now..."
    if (-not (Test-Path "samconfig.toml")) {
        Write-Host "No samconfig.toml found -- running guided setup..."
        Write-Host "Enter your API key when prompted (ApiKey parameter)."
        Write-Host "Accept defaults for other parameters."
        Write-Host "Stack name is pre-set to '$STACK_NAME'."
        sam deploy --guided --stack-name $STACK_NAME --s3-bucket $S3_BUCKET --capabilities CAPABILITY_NAMED_IAM
    } else {
        sam deploy --stack-name $STACK_NAME --s3-bucket $S3_BUCKET --capabilities CAPABILITY_NAMED_IAM
    }
    Write-Host "Stack created."
}

# --- Step 7: Get stack outputs ---
Write-Host ""
Write-Host "[7/11] Retrieving stack outputs..."

$ECR_URI = aws cloudformation describe-stacks `
    --stack-name $STACK_NAME `
    --region $REGION `
    --query "Stacks[0].Outputs[?OutputKey=='ECRRepositoryURI'].OutputValue" `
    --output text

$CLUSTER = aws cloudformation describe-stacks `
    --stack-name $STACK_NAME `
    --region $REGION `
    --query "Stacks[0].Outputs[?OutputKey=='ECSClusterName'].OutputValue" `
    --output text

$SERVICE = aws cloudformation describe-stacks `
    --stack-name $STACK_NAME `
    --region $REGION `
    --query "Stacks[0].Outputs[?OutputKey=='ECSServiceName'].OutputValue" `
    --output text

if (-not $ECR_URI -or -not $CLUSTER -or -not $SERVICE) {
    Write-Host "Error: Failed to retrieve stack outputs."
    exit 1
}

Write-Host "ECR URI:  $ECR_URI"
Write-Host "Cluster:  $CLUSTER"
Write-Host "Service:  $SERVICE"

# --- Step 8: Authenticate Docker to ECR ---
Write-Host ""
Write-Host "[8/11] Authenticating Docker to ECR..."

aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_URI

Write-Host "Docker authenticated to ECR."

# --- Step 9: Tag and push image to ECR (pinned tag + latest) ---
Write-Host ""
Write-Host "[9/11] Pushing image to ECR..."

docker tag ${IMAGE_NAME}:latest ${ECR_URI}:latest
docker tag ${IMAGE_NAME}:latest ${ECR_URI}:${Tag}
docker push ${ECR_URI}:latest
docker push ${ECR_URI}:${Tag}

Write-Host "Image pushed to ECR (latest + $Tag)."

# --- Step 10: Scale up to 1 (first deploy deploys with DesiredCount=0) ---
Write-Host ""
Write-Host "[10/11] Scaling service to 1 task..."

aws ecs update-service `
    --cluster $CLUSTER `
    --service $SERVICE `
    --desired-count 1 `
    --region $REGION | Out-Null

Write-Host "Service scaled to 1 task."

# --- Step 11: Deploy pinned tag with rollback protection ---
Write-Host ""
Write-Host "[11/11] Deploying pinned image tag '$Tag' with rollback protection..."

& "$PSScriptRoot\rollback.ps1" -Env $Env -Tag $Tag
