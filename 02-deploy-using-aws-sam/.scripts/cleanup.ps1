param(
    [string]$Env = "dev"
)

$ErrorActionPreference = "Stop"

$REGION = "ap-southeast-1"

# --- Function: Delete a single environment ---
function Delete-Env {
    param([string]$TargetEnv)

    $STACK_NAME = "node-app-$TargetEnv"

    Write-Host "--------------------------------------------"
    Write-Host " Deleting: $TargetEnv"
    Write-Host " Stack:    $STACK_NAME"
    Write-Host "--------------------------------------------"

    # Delete the stack via SAM. On failure we ABORT the whole cleanup and
    # leave the resources intact (rollback-style) instead of force-deleting
    # the ECR repository and escalating the damage.
    try {
        $null = & { sam delete --stack-name $STACK_NAME --region $REGION --no-prompts } 2>&1
        if ($LASTEXITCODE -ne 0) { throw "sam delete failed" }
    } catch {
        Write-Host ""
        Write-Host "[ROLLBACK] Cleanup aborted - 'sam delete' failed."
        Write-Host " Stack '$STACK_NAME' and its resources were left intact."
        Write-Host ""
        exit 1
    }

    # Confirm the stack is really gone before touching anything else
    # try/catch: when the stack no longer exists, `aws` prints an error to
    # stderr, which PowerShell 5.1 turns into a terminating error under
    # $ErrorActionPreference = "Stop" (previously crashed the script)
    try {
        $STACK_STATUS = & { aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query "Stacks[0].StackStatus" --output text } 2>$null
    } catch {
        $STACK_STATUS = ""
    }
    if (-not $STACK_STATUS) { $STACK_STATUS = "NOT_FOUND" }

    if ($STACK_STATUS -ne "NOT_FOUND" -and $STACK_STATUS -ne "DELETE_COMPLETE") {
        Write-Host ""
        Write-Host "[ROLLBACK] Cleanup aborted - stack '$STACK_NAME' still exists (status: $STACK_STATUS)."
        Write-Host " Resources were left intact."
        Write-Host ""
        exit 1
    }

    Write-Host "Stack '$STACK_NAME' deleted."

    # Delete the custom S3 deployment bucket
    $ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
    $S3_BUCKET = "sam-deploy-$ACCOUNT_ID"
    $null = aws s3 rb "s3://$S3_BUCKET" --force 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "S3 bucket '$S3_BUCKET' deleted."
    }
}

# --- Main ---
if ($Env -eq "all") {
    $ENVIRONMENTS = @("dev", "staging", "prod")

    Write-Host "============================================"
    Write-Host " Deleting ALL environments"
    Write-Host " Environments: $($ENVIRONMENTS -join ', ')"
    Write-Host " Region:       $REGION"
    Write-Host "============================================"
    Write-Host ""
    Write-Host "This will delete ALL resources for dev, staging, and prod."
    Write-Host ""

    $CONFIRM = Read-Host "Are you sure? (y/N)"
    if ($CONFIRM -ne "y" -and $CONFIRM -ne "Y") {
        Write-Host "Cleanup cancelled."
        exit 0
    }

    foreach ($TARGET_ENV in $ENVIRONMENTS) {
        Delete-Env -TargetEnv $TARGET_ENV
    }

    Write-Host ""
    Write-Host "[Final] Removing local build artifacts..."
    if (Test-Path ".aws-sam") {
        Remove-Item -Recurse -Force ".aws-sam"
        Write-Host ".aws-sam/ removed."
    } else {
        Write-Host "No .aws-sam/ directory found, skipping."
    }

    Write-Host ""
    Write-Host "============================================"
    Write-Host " Cleanup Complete!"
    Write-Host "============================================"
    Write-Host ""
    Write-Host " All environments (dev, staging, prod) have been deleted."
    Write-Host ""

} else {
    $STACK_NAME = "node-app-$Env"

    Write-Host "============================================"
    Write-Host " Deleting environment: $Env"
    Write-Host " Stack name:           $STACK_NAME"
    Write-Host " Region:               $REGION"
    Write-Host "============================================"
    Write-Host ""
    Write-Host "This will delete ALL resources for the '$Env' environment:"
    Write-Host "  - ECS service and cluster"
    Write-Host "  - Task definition"
    Write-Host "  - ECR repository"
    Write-Host "  - VPC and networking resources"
    Write-Host "  - IAM role"
    Write-Host "  - Secrets Manager secrets"
    Write-Host "  - CloudWatch log group"
    Write-Host ""

    $CONFIRM = Read-Host "Are you sure? (y/N)"
    if ($CONFIRM -ne "y" -and $CONFIRM -ne "Y") {
        Write-Host "Cleanup cancelled."
        exit 0
    }

    Delete-Env -TargetEnv $Env

    Write-Host ""
    Write-Host "[2/2] Removing local build artifacts..."
    if (Test-Path ".aws-sam") {
        Remove-Item -Recurse -Force ".aws-sam"
        Write-Host ".aws-sam/ removed."
    } else {
        Write-Host "No .aws-sam/ directory found, skipping."
    }

    Write-Host ""
    Write-Host "============================================"
    Write-Host " Cleanup Complete!"
    Write-Host "============================================"
    Write-Host ""
    Write-Host " All resources for '$Env' have been deleted."
    Write-Host ""
}
