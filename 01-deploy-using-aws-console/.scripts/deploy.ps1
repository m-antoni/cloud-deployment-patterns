param(
    [string]$Env = "dev"
)

$ErrorActionPreference = "Stop"

$REGION = "ap-southeast-1"

Write-Host "============================================"
Write-Host " AWS ECR Deploy Script"
Write-Host "============================================"

# --- Step 1: Check prerequisites ---
Write-Host ""
Write-Host "[1/5] Checking prerequisites..."

if (-not (Get-Command "aws" -ErrorAction SilentlyContinue)) {
    Write-Host "Error: AWS CLI not found."
    exit 1
}

if (-not (Get-Command "docker" -ErrorAction SilentlyContinue)) {
    Write-Host "Error: Docker not found."
    exit 1
}

if (-not (docker info 2>$null | Out-String | Select-String "Server Version")) {
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

# --- Step 2: Cleanup old containers and images ---
Write-Host ""
Write-Host "[2/5] Cleaning up old containers and images..."

docker ps -q 2>$null | ForEach-Object { docker stop $_ 2>$null }
docker ps -aq 2>$null | ForEach-Object { docker rm $_ 2>$null }
docker images -q 2>$null | ForEach-Object { docker rmi $_ 2>$null }
docker system prune -a --force 2>$null

Write-Host "Cleanup completed!"

# --- Step 3: Build Docker image ---
Write-Host ""
Write-Host "[3/5] Building Docker image..."

docker build -t node-app .
Write-Host "Docker image built successfully!"

# --- Step 4: Create nginx.conf from template ---
Write-Host ""
Write-Host "[4/5] Creating nginx.conf from template..."

if (-not (Test-Path "nginx.conf")) {
    Copy-Item "nginx.conf.example" "nginx.conf"
    Write-Host "nginx.conf created."
} else {
    Write-Host "nginx.conf already exists, skipping."
}

# --- Step 5: Authenticate, tag, and push to ECR ---
Write-Host ""
Write-Host "[5/5] Authenticating and pushing to ECR..."

$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
$ECR_URI = "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

Write-Host "Authenticating to ECR..."
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_URI
Write-Host "Authenticated successfully!"

Write-Host "Tagging image..."
docker tag node-app:latest "${ECR_URI}/node-app:latest"
Write-Host "Image tagged successfully!"

Write-Host "Pushing image to ECR..."
docker push "${ECR_URI}/node-app:latest"
Write-Host "Image pushed to ECR successfully!"

Write-Host ""
Write-Host "============================================"
Write-Host " Deployment Complete!"
Write-Host "============================================"
