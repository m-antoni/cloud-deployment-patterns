param(
    [string]$Env = "dev",
    [string]$Tag = "",
    [switch]$Manual
)

$ErrorActionPreference = "Stop"

# ============================================================
# Rollback / Pinned Deploy Script for Node.js App on AWS ECS Fargate
# ============================================================
# Deploys a pinned image tag (e.g. a git SHA) through CloudFormation and
# automatically reverts the service to the previously deployed tag when the
# new deployment never becomes healthy (rollback on failure).
#
# Usage:
#   .\rollback.ps1 -Env dev -Tag <image-tag>          # auto: revert on failure
#   .\rollback.ps1 -Env dev -Tag <image-tag> -Manual   # manual: no auto-revert
# ============================================================

if (-not $Tag) {
    Write-Host "Error: -Tag is required (e.g. -Tag <git-sha> or -Tag latest)"
    exit 1
}

$STACK_NAME = "node-app-$Env"
$REGION = "ap-southeast-1"
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
$S3_BUCKET = "sam-deploy-$ACCOUNT_ID"
$ECR_URI = "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$Env-node-app"

Write-Host "============================================"
Write-Host " Pinned deploy/rollback to: $Env"
Write-Host " Image tag:  $Tag"
Write-Host " Stack name: $STACK_NAME"
Write-Host " Region:     $REGION"
Write-Host "============================================"

# --- Step 1: Get stack outputs ---
Write-Host ""
Write-Host "[1/5] Retrieving stack outputs..."

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

if (-not $CLUSTER -or -not $SERVICE -or $CLUSTER -eq "None" -or $SERVICE -eq "None") {
    Write-Host "Error: Failed to retrieve stack outputs. Is the stack '$STACK_NAME' deployed?"
    exit 1
}

Write-Host "Cluster:  $CLUSTER"
Write-Host "Service:  $SERVICE"

# --- Step 2: Capture the currently deployed image tag (rollback target) ---
Write-Host ""
Write-Host "[2/5] Capturing currently deployed tag..."

$PREV_TAG = ""
if (-not $Manual) {
    $TASK_DEF_ARN = ""
    try {
        $TASK_DEF_ARN = aws ecs describe-services `
            --cluster $CLUSTER `
            --services $SERVICE `
            --region $REGION `
            --query "services[0].taskDefinition" `
            --output text 2>$null
    } catch {
        # transient error; treat as no previous tag
    }

    if ($TASK_DEF_ARN -and $TASK_DEF_ARN -ne "None") {
        try {
            $CURRENT_IMAGE = aws ecs describe-task-definition `
                --task-definition $TASK_DEF_ARN `
                --region $REGION `
                --query "taskDefinition.containerDefinitions[0].image" `
                --output text 2>$null
        } catch {
            $CURRENT_IMAGE = ""
        }
        if ($CURRENT_IMAGE) {
            $PREV_TAG = $CURRENT_IMAGE.Split(':')[-1]
        }
    }

    if ($PREV_TAG -and $PREV_TAG -ne $Tag) {
        Write-Host "Previous deployed tag: $PREV_TAG"
    } else {
        $PREV_TAG = ""
        Write-Host "No previous tag to roll back to (first deploy or same tag)."
    }
}

# --- Step 3: Deploy the pinned tag via CloudFormation ---
Write-Host ""
Write-Host "[3/5] Deploying stack with ImageTag=$Tag..."

sam deploy `
    --stack-name $STACK_NAME `
    --region $REGION `
    --s3-bucket $S3_BUCKET `
    --capabilities CAPABILITY_NAMED_IAM `
    --parameter-overrides "Environment=$Env" "ImageTag=$Tag" `
    --no-confirm-changeset `
    --no-fail-on-empty-changeset
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: sam deploy failed. CloudFormation rolls back failed updates automatically."
    exit 1
}

Write-Host "Stack deployment completed."

# --- Step 4: Wait for the ECS service deployment to become stable ---
Write-Host ""
Write-Host "[4/5] Waiting for the ECS service deployment to complete..."

$DEPLOY_OK = $false
for ($i = 1; $i -le 60; $i++) {
    $ROLLOUT = ""
    try {
        $ROLLOUT = aws ecs describe-services `
            --cluster $CLUSTER `
            --services $SERVICE `
            --region $REGION `
            --query "services[0].deployments[0].rolloutState" `
            --output text 2>$null
    } catch {
        # transient error; keep polling
    }

    Write-Host "  Deployment status: $ROLLOUT ($i/60)"

    if ($ROLLOUT -eq "COMPLETED") {
        $DEPLOY_OK = $true
        break
    }

    if ($ROLLOUT -eq "FAILED") {
        break
    }

    Start-Sleep -Seconds 10
}

if (-not $DEPLOY_OK) {
    Write-Host ""
    Write-Host "ERROR: Deployment of tag '$Tag' did not complete successfully."

    if ($PREV_TAG) {
        Write-Host "[ROLLBACK] Reverting to previous tag: $PREV_TAG..."
        sam deploy `
            --stack-name $STACK_NAME `
            --region $REGION `
            --s3-bucket $S3_BUCKET `
            --capabilities CAPABILITY_NAMED_IAM `
            --parameter-overrides "Environment=$Env" "ImageTag=$PREV_TAG" `
            --no-confirm-changeset `
            --no-fail-on-empty-changeset
        $null = aws ecs wait services-stable --cluster $CLUSTER --services $SERVICE --region $REGION 2>&1
        Write-Host "[ROLLBACK] Reverted to '$PREV_TAG'."
    } else {
        Write-Host "[ROLLBACK] No previous tag available - cannot roll back."
    }

    Write-Host ""
    Write-Host "============================================"
    Write-Host " Deployment FAILED!"
    Write-Host "============================================"
    Write-Host ""
    exit 1
}

# --- Step 5: Retrieve the app URL ---
Write-Host ""
Write-Host "[5/5] Waiting for the task to start and retrieving the app URL..."

$PUBLIC_IP = ""
for ($i = 1; $i -le 15; $i++) {
    try {
        $TASK_ARN = aws ecs list-tasks `
            --cluster $CLUSTER `
            --service-name $SERVICE `
            --region $REGION `
            --query "taskArns[0]" `
            --output text 2>$null

        if ($TASK_ARN -and $TASK_ARN -ne "None") {
            $ENI_ID = aws ecs describe-tasks `
                --cluster $CLUSTER `
                --tasks $TASK_ARN `
                --region $REGION `
                --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" `
                --output text 2>$null

            if ($ENI_ID -and $ENI_ID -ne "None") {
                $PUBLIC_IP = aws ec2 describe-network-interfaces `
                    --network-interface-ids $ENI_ID `
                    --region $REGION `
                    --query "NetworkInterfaces[0].Association.PublicIp" `
                    --output text 2>$null
            }
        }
    } catch {
        # transient AWS error while the task starts; keep polling
    }

    if ($PUBLIC_IP -and $PUBLIC_IP -ne "None") {
        break
    }

    Write-Host "  Task still starting up... ($i/15)"
    Start-Sleep -Seconds 10
}

if ($PUBLIC_IP -and $PUBLIC_IP -ne "None") {
    Write-Host ""
    Write-Host "============================================"
    Write-Host " Deployment Complete!"
    Write-Host "============================================"
    Write-Host ""
    Write-Host " App URL: http://$PUBLIC_IP"
    Write-Host " Weather: http://$PUBLIC_IP/weather?q=manila"
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "============================================"
    Write-Host " Deployment Complete!"
    Write-Host "============================================"
    Write-Host ""
    Write-Host " Note: Could not retrieve the public IP yet."
    Write-Host " Check the ECS console for the task's public IP."
    Write-Host ""
}
