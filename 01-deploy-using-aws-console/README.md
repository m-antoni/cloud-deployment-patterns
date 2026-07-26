# Deploy Using AWS Console

Deploy the Node.js app to AWS ECS Fargate manually using the AWS Management Console.

## Prerequisites

- Node.js 22+
- Docker
- AWS CLI configured

## Architecture

```
┌── VPC (10.0.0.0/16) ───────────────────────────────────┐
│                                                         │
│ ┌── ECS Fargate Cluster ──────────────────────────────┐ │
│ │ Cluster: node-app-dev-cluster                       │ │
│ │                                                     │ │
│ │ ┌── Service: node-app-dev-service ────────────────┐ │ │
│ │ │                                                 │ │ │
│ │ │  [ Task 1: Nginx :80 → Node.js :5000 ]          │ │ │
│ │ └─────────────────────────────────────────────────┘ │ │
│ └─────────────────────────────────────────────────────┘ │
│                                                         │
│  Public Subnets ──▶ Security Group ──▶ ENI             │
└─────────────────────────────────────────────────────────┘
```

## Local Development

```bash
npm install
npm run dev
```

## API Usage

```
GET /weather?q=manila
```

## Docker

```bash
# 1. Create nginx.conf from template
cp nginx.conf.example nginx.conf

# 2. Edit nginx.conf - replace yourdomain.com with your domain
# 3. Build and run
docker build -t node-app .
docker run -p 80:80 -e API_ENDPOINT=https://api.openweathermap.org -e API_KEY=<API_KEY> node-app
```

## AWS Deployment

### 1. Create ECR Repository

1. Go to **AWS Console** > **ECR** > **Repositories**
2. Click **Create repository**
3. Enter repository name: `node-app`
4. Click **Create repository**

#### 1.1 Push Image

1. Select your new repository
2. Click **View push commands**
3. Follow the 4 commands shown — they will be specific to your account and region:

   - **Command 1**: Authenticate Docker to ECR

   ```bash
   aws ecr get-login-password --region <your-region> | docker login --username AWS --password-stdin <your-account-id>.dkr.ecr.<your-region>.amazonaws.com
   ```

   - **Command 2**: Build your image

   ```bash
   docker build -t node-app .
   ```

   - **Command 3**: Tag your image

   ```bash
   docker tag node-app:latest <your-account-id>.dkr.ecr.<your-region>.amazonaws.com/node-app:latest
   ```

   - **Command 4**: Push your image

   ```bash
   docker push <your-account-id>.dkr.ecr.<your-region>.amazonaws.com/node-app:latest
   ```

### 2. Create Secrets

1. Go to **AWS Console** > **Secrets Manager**
2. Click **Store a new secret**
3. Select **Other type of secret**
4. Enter:
   - Key: `API_ENDPOINT`, Value: `https://api.openweathermap.org`
5. Enter name: `dev/node-app-api-endpoint`
6. Click **Store**
7. Repeat for API Key:
   - Key: `API_KEY`, Value: your API key
   - Name: `dev/node-app-api-key`
   - Click **Store**

### 3. Create IAM Role

1. Go to **AWS Console** > **IAM** > **Roles**
2. Click **Create role**
3. Select **AWS service** as trusted entity
4. Choose **Elastic Container Service** as use case
5. Select **Elastic Container Service Task** and click **Next**
6. Click **Create policy** (opens new tab)
7. Select **JSON** tab and enter:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": [
        "arn:aws:secretsmanager:ap-southeast-1:<AWS_ID>:secret:dev/node-app-*"
      ]
    }
  ]
}
```

8. Name policy: `node-app-ecs-secrets-policy` > Click **Create policy**
9. Go back to role creation tab > refresh policies
10. Search and select `node-app-ecs-secrets-policy`
11. Also select `AmazonECSTaskExecutionRolePolicy`
12. Click **Next**
13. Enter role name: `ECSTaskExecutionRoleSecrets`
14. Click **Create role**

### 4. Deploy to ECS Fargate

#### 4.1 Create ECS Cluster

1. Go to **AWS Console** > **ECS** > **Clusters**
2. Click **Create cluster**
3. Select **Fargate** as infrastructure type
4. Enter cluster name: `node-app-dev-cluster` and click **Create**

#### 4.2 Create Task Definition

1. Go to **Task Definitions** > **Create new Task Definition**
2. Enter family name: `node-app-dev-task`
3. Select **Fargate** launch type
4. Under **Task execution role**, select `ECSTaskExecutionRoleSecrets`
5. Add container with your ECR image URI
6. Under **Port mappings**, set container ports to `80` and `443`
7. Under **Environment variables**, value type > **ValueFrom** add both from Secrets Manager ARN:
   - `API_ENDPOINT` → `arn:aws:secretsmanager:ap-southeast-1:<AWS_ID>:secret:dev/node-app-api-endpoint-XXXXXX::`
   - `API_KEY` → `arn:aws:secretsmanager:ap-southeast-1:<AWS_ID>:secret:dev/node-app-api-key-XXXXXX::`
8. Click **Create**

#### 4.3 Create VPC

1. Go to **AWS Console** > **VPC** > **Your VPCs**
2. Click **Create VPC**
3. Select **VPC and more**
4. Set **IPv4 CIDR** = `10.0.0.0/16`
5. Set **Public subnets** = 2
6. Click **Create VPC**

#### 4.4 Create Security Group

1. Go to **AWS Console** > **VPC** > **Security Groups**
2. Click **Create security group**
3. Enter name: `node-app-sg`
4. Select your VPC
5. Under **Inbound rules**, click **Add rule**:
   - Type: **HTTP**, Port: `80`, Source: **Anywhere** (`0.0.0.0/0`)
   - Type: **HTTPS**, Port: `443`, Source: **Anywhere** (`0.0.0.0/0`)
6. Click **Create security group**

#### 4.5 Create Service

1. Go to **AWS Console** > **ECS** > **Clusters** > `node-app-dev-cluster`
2. Click **Services** > **Create**
3. Select your task definition
4. Under **Networking**, select:
   - VPC: your VPC
   - Subnets: 2 Public Subnets
   - Security groups: `node-app-sg`
5. Enable **Auto-assign public IP**
6. Click **Create service**

> **Note:** Service creation takes 2-5 minutes. AWS is provisioning Fargate infrastructure, pulling your Docker image from ECR, starting the container, configuring networking (ENI, public IP), and running health checks. If it takes longer, check the **Events** tab for errors.

### 5. Access the Web App

1. Go to **ECS** > **Clusters** > `node-app-dev-cluster`
2. Click on your service (`node-app-dev-service`)
3. Click on the **Tasks** tab
4. Click on the running task
5. Under **Network** section, copy the **Public IP**
6. Open in browser:
   ```
   http://<PUBLIC_IP>
   http://<PUBLIC_IP>/weather?q=manila
   ```

> **Note:** App runs on port 80. SSL is available but commented out in nginx.conf.

## Updating & Deploying Code Changes

### 1. Rebuild Docker Image Locally

```bash
docker build -t node-app .
```

### 2. Authenticate & Push to ECR

```bash
# Authenticate to ECR
aws ecr get-login-password --region <REGION> | docker login --username AWS --password-stdin <AWS_ID>.dkr.ecr.<REGION>.amazonaws.com

# Tag the image
docker tag node-app:latest <AWS_ID>.dkr.ecr.<REGION>.amazonaws.com/node-app:latest

# Push to ECR
docker push <AWS_ID>.dkr.ecr.<REGION>.amazonaws.com/node-app:latest
```

### 3. Create New Task Definition Revision

1. Go to **ECS** > **Task Definitions** > `node-app-dev-task`
2. Click **Create new revision**
3. Confirm image URI is correct (same ECR URI, new image pushed)
4. Click **Create**

### 4. Update Service with New Revision

1. Go to **ECS** > **Clusters** > `node-app-dev-cluster`
2. Click on your service (`node-app-dev-service`)
3. Click **Update**
4. Select the new task definition revision
5. Click **Update**

> **Note:** ECS will automatically pull the new image and restart your tasks with zero downtime.

> **Note:** `nginx.conf` is excluded from git (in `.gitignore`). If you make changes to `nginx.conf`, you must rebuild the Docker image locally and push to ECR before creating a new task definition revision.

## Troubleshooting

### Checking Logs

1. Go to **ECS** > **Clusters** > `node-app-dev-cluster`
2. Click on your service (`node-app-dev-service`)
3. Click on the **Tasks** tab
4. Click on the running task
5. Click on the **Logs** tab to view container logs
6. Or click on the **CloudWatch Logs** link to open in a new tab

### Updating Task Definition (New Revision)

1. Go to **ECS** > **Task Definitions** > `node-app-dev-task`
2. Click **Create new revision**
3. Make necessary changes (secrets, image, IAM role, etc.)
4. Click **Create**

### Deregistering Old Revision

1. Go to **ECS** > **Task Definitions**
2. Select old revision from dropdown
3. Click **Actions** > **Deregister**

### Updating Service with New Revision

1. Go to **ECS** > **Clusters** > `node-app-dev-cluster`
2. Click on your service (`node-app-dev-service`)
3. Click **Update**
4. Select the new task definition revision
5. Click **Update**

## Rollback / Cleanup

Delete all AWS resources to avoid unnecessary charges.

### Using Cleanup Script (Recommended)

A cleanup script is provided in `.scripts/cleanup.sh` that automates the entire deletion process:

```bash
# Run the cleanup script
chmod +x .scripts/cleanup.sh
./scripts/cleanup.sh
```

This script will:
1. Delete ECS Service and wait for it to become inactive
2. Delete ECS Cluster
3. Deregister and delete all Task Definition revisions
4. Delete ECR Repository
5. Delete Secrets from Secrets Manager
6. Detach policies and delete IAM Role
7. Delete VPC networking (VPC Endpoints, IGW, Subnets, Route Tables, SG, VPC)

### Using AWS CLI

```bash
# Delete ECS service (dynamically looks up services in cluster)
SERVICES=$(aws ecs list-services --cluster node-app-dev-cluster --query "serviceArns[]" --output text)
for SVC in $SERVICES; do
    aws ecs delete-service --cluster node-app-dev-cluster --service "$SVC" --force
done
aws ecs wait services-inactive --cluster node-app-dev-cluster --services $SERVICES

# Delete ECS cluster
aws ecs delete-cluster --cluster node-app-dev-cluster

# Delete task definitions (dynamically looks up all revisions)
TASK_DEFS=$(aws ecs list-task-definitions --family-prefix node-app-dev-task --query "taskDefinitionArns[]" --output text)
for TASK_DEF in $TASK_DEFS; do
    aws ecs deregister-task-definition --task-definition "$TASK_DEF"
done
aws ecs delete-task-definitions --task-definitions $TASK_DEFS

# Delete ECR repository
aws ecr delete-repository --repository-name node-app --force

# Delete secrets
aws secretsmanager delete-secret --secret-id dev/node-app-api-endpoint --force-delete-without-recovery
aws secretsmanager delete-secret --secret-id dev/node-app-api-key --force-delete-without-recovery

# Delete IAM role
aws iam delete-role-policy --role-name ECSTaskExecutionRoleSecrets --policy-name GetSecretsValue-node-app-ecs-deploy
aws iam detach-role-policy --role-name ECSTaskExecutionRoleSecrets --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
aws iam delete-role --role-name ECSTaskExecutionRoleSecrets

# Delete VPC networking (looked up by SG name)
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=node-app-sg" --query "SecurityGroups[0].GroupId" --output text)
VPC_ID=$(aws ec2 describe-security-groups --group-ids "$SG_ID" --query "SecurityGroups[0].VpcId" --output text)

# Delete VPC Endpoints
for VPCE in $(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --query "VpcEndpoints[*].VpcEndpointId" --output text); do
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$VPCE"
done

# Delete Internet Gateways
for IGW in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[*].InternetGatewayId" --output text); do
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID"
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW"
done

# Delete Subnets
for SUBNET in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[*].SubnetId" --output text); do
    aws ec2 delete-subnet --subnet-id "$SUBNET"
done

# Delete Route Tables (excluding main)
for RTB in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text); do
    aws ec2 delete-route-table --route-table-id "$RTB"
done

aws ec2 delete-security-group --group-id "$SG_ID"
aws ec2 delete-vpc --vpc-id "$VPC_ID"
```

### Using AWS Console (UI)

1. Go to **ECS** > **Clusters** > select cluster
2. Select service > **Update** > set desired count to **0** > save
3. Select service > **Delete**
4. Go to **Task Definitions** > select task > **Deregister**
5. Go to **ECS** > **Clusters** > select cluster > **Delete**
6. Go to **ECR** > select repository > **Delete**
7. Go to **Secrets Manager** > select `dev/node-app-api-endpoint` > **Delete**
8. Go to **Secrets Manager** > select `dev/node-app-api-key` > **Delete**
9. Go to **IAM** > **Roles** > select `ECSTaskExecutionRoleSecrets` > **Delete**
10. Go to **VPC** > **Security Groups** > select `node-app-sg` > **Delete**
11. Go to **VPC** > **Your VPCs** > select VPC > **Delete** (delete subnets first)
