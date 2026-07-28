$ErrorActionPreference = "Stop"

$REGION = "ap-southeast-1"
$CLUSTER_NAME = "node-app-dev-cluster"
$FAMILY_PREFIX = "node-app-dev-task"
$ECR_REPO = "node-app"

Write-Host "============================================"
Write-Host " Cleanup: node-app-dev"
Write-Host " Region:  $REGION"
Write-Host "============================================"

# --- 1. Cluster / Service / Task Definition cleanup ---
Write-Host ""
Write-Host "[1/5] Cleaning up ECS resources..."

$SERVICES = aws ecs list-services --cluster $CLUSTER_NAME --query "serviceArns[]" --output text
if ($SERVICES) {
    foreach ($SVC in $SERVICES) {
        Write-Host "Deleting ECS Service: $SVC"
        aws ecs delete-service --cluster $CLUSTER_NAME --service "$SVC" --force 2>$null
    }
    Write-Host "Waiting for services to become inactive..."
    aws ecs wait services-inactive --cluster $CLUSTER_NAME --services $SERVICES 2>$null
}

Write-Host "Deleting ECS Cluster..."
aws ecs delete-cluster --cluster $CLUSTER_NAME 2>$null

Write-Host "Deregistering and deleting Task Definitions..."
$TASK_DEFS = aws ecs list-task-definitions --family-prefix $FAMILY_PREFIX --query "taskDefinitionArns[]" --output text
if ($TASK_DEFS) {
    foreach ($TASK_DEF in $TASK_DEFS) {
        Write-Host "Deregistering: $TASK_DEF"
        aws ecs deregister-task-definition --task-definition "$TASK_DEF" 2>$null
    }
    aws ecs delete-task-definitions --task-definitions $TASK_DEFS 2>$null
}

# --- 2. ECR cleanup ---
Write-Host ""
Write-Host "[2/5] Deleting ECR Repository..."
aws ecr delete-repository --repository-name $ECR_REPO --force 2>$null

# --- 3. Secrets Manager cleanup ---
Write-Host ""
Write-Host "[3/5] Deleting Secrets..."
aws secretsmanager delete-secret --secret-id dev/node-app-api-endpoint --force-delete-without-recovery 2>$null
aws secretsmanager delete-secret --secret-id dev/node-app-api-key --force-delete-without-recovery 2>$null

# --- 4. IAM cleanup ---
Write-Host ""
Write-Host "[4/5] Cleaning up IAM Role..."
aws iam delete-role-policy --role-name ECSTaskExecutionRoleSecrets --policy-name GetSecretsValue-node-app-ecs-deploy 2>$null
aws iam detach-role-policy --role-name ECSTaskExecutionRoleSecrets --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>$null
aws iam delete-role --role-name ECSTaskExecutionRoleSecrets 2>$null

# --- 5. VPC cleanup ---
Write-Host ""
Write-Host "[5/5] Cleaning up VPC resources..."

$SG_ID = aws ec2 describe-security-groups --filters "Name=group-name,Values=node-app-sg" --query "SecurityGroups[0].GroupId" --output text
if ($SG_ID -and $SG_ID -ne "None") {
    $VPC_ID = aws ec2 describe-security-groups --group-ids "$SG_ID" --query "SecurityGroups[0].VpcId" --output text

    # Delete VPC Endpoints
    $VPCES = aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --query "VpcEndpoints[*].VpcEndpointId" --output text
    if ($VPCES) {
        Write-Host "Deleting VPC Endpoints..."
        aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $VPCES 2>$null
    }

    # Delete Internet Gateways
    $IGWS = aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[*].InternetGatewayId" --output text
    if ($IGWS) {
        foreach ($IGW in $IGWS) {
            Write-Host "Detaching and deleting IGW: $IGW"
            aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" 2>$null
            aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" 2>$null
        }
    }

    # Delete Subnets
    $SUBNETS = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[*].SubnetId" --output text
    if ($SUBNETS) {
        foreach ($SUBNET in $SUBNETS) {
            Write-Host "Deleting Subnet: $SUBNET"
            aws ec2 delete-subnet --subnet-id "$SUBNET" 2>$null
        }
    }

    # Delete Route Tables
    $RTBS = aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text
    if ($RTBS) {
        foreach ($RTB in $RTBS) {
            Write-Host "Deleting Route Table: $RTB"
            aws ec2 delete-route-table --route-table-id "$RTB" 2>$null
        }
    }

    Write-Host "Deleting Security Group..."
    aws ec2 delete-security-group --group-id "$SG_ID" 2>$null

    if ($VPC_ID -and $VPC_ID -ne "None") {
        Write-Host "Deleting VPC..."
        aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>$null
    }
}

Write-Host ""
Write-Host "============================================"
Write-Host " Cleanup Complete!"
Write-Host "============================================"
