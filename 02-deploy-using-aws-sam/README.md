# Deploy Using AWS SAM

Deploy the Node.js app to AWS ECS Fargate using AWS SAM (Serverless Application Model).

## Prerequisites

Before deploying, ensure the following tools are installed and configured:

### 1. AWS CLI — configured with credentials

```bash
aws sts get-caller-identity
```

Expected output: your account ID, user ARN, and user ID. If not configured, run `aws configure`.

### 2. AWS SAM CLI — installed

```bash
sam --version
```

### 3. Docker — installed and running

```bash
docker info
```

If Docker is not running, start Docker Desktop or the Docker service.

### 4. Node.js 22+

```bash
node --version
```

## Architecture

```
┌── VPC (10.0.0.0/16) ────────────────────────────────────┐
│                                                         │
│  Public Subnet 1          Public Subnet 2               │
│  (10.0.1.0/24)            (10.0.2.0/24)                 │
│                                                         │
│  Internet Gateway ◄── Route Table                       │
│                                                         │
│  Security Group (HTTP:80, HTTPS:443 from 0.0.0.0/0)     │
│                                                         │
│  ┌── ECS Fargate Cluster ─────────────────────────────┐ │
│  │ Task Definition: node-app-task                     │ │
│  │   - nginx :80/:443 → node.js :5000                 │ │
│  │   - Secrets: API_ENDPOINT, API_KEY                 │ │
│  │                                                    │ │
│  │ Service: node-app-service                          │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘

Additional Resources:
  - ECR Repository: {env}-node-app
  - Secrets Manager: {env}/node-app-api-endpoint
  - Secrets Manager: {env}/node-app-api-key
  - IAM Role: {env}-ECSTaskExecutionRoleSecrets
  - CloudWatch Log Group: /ecs/{env}-node-app
```

## Resources Created

| Resource                         | Description                          |
| -------------------------------- | ------------------------------------ |
| `ECRRepository`                  | ECR repo for Docker images           |
| `VPC`                            | Virtual Private Cloud (10.0.0.0/16)  |
| `PublicSubnet1`, `PublicSubnet2` | Public subnets in 2 AZs              |
| `InternetGateway`                | Internet access for public subnets   |
| `PublicRouteTable`               | Routes traffic to IGW                |
| `SecurityGroup`                  | Allows HTTP/HTTPS inbound            |
| `ApiEndpointSecret`              | Secrets Manager - API endpoint       |
| `ApiKeySecret`                   | Secrets Manager - API key            |
| `ECSTaskExecutionRole`           | IAM role with Secrets Manager access |
| `ECSCluster`                     | ECS Fargate cluster                  |
| `TaskDefinition`                 | ECS task definition                  |
| `LogGroup`                       | CloudWatch logs                      |
| `ECSService`                     | ECS service running the app          |

## Parameters

| Parameter           | Default                          | Description                                       |
| ------------------- | -------------------------------- | ------------------------------------------------- |
| `Environment`       | `dev`                            | Deployment environment (`dev`, `staging`, `prod`) |
| `VpcCidr`           | `10.0.0.0/16`                    | VPC CIDR block                                    |
| `PublicSubnet1Cidr` | `10.0.1.0/24`                    | Subnet 1 CIDR                                     |
| `PublicSubnet2Cidr` | `10.0.2.0/24`                    | Subnet 2 CIDR                                     |
| `ContainerPort`     | `80`                             | Container port (nginx)                            |
| `TaskPort`          | `443`                            | Container port (HTTPS)                            |
| `DesiredCount`      | `1`                              | Number of ECS tasks                               |
| `Cpu`               | `256`                            | Fargate CPU units                                 |
| `Memory`            | `512`                            | Fargate memory (MiB)                              |
| `ApiEndpoint`       | `https://api.openweathermap.org` | Weather API endpoint                              |
| `ApiKey`            | _(required)_                     | Weather API key                                   |

## Configuration Files

Before deploying, you need to configure one file:

### `samconfig.toml`

SAM CLI's configuration file. Stores your deployment settings (stack name, region, parameter overrides) so you don't have to type them every time.

**Setup:**

```bash
# Copy the example template
cp samconfig.toml.example samconfig.toml

# Then edit samconfig.toml with your actual API key
```

```toml
# samconfig.toml
version = 0.1

[default]
[default.deploy]
[default.deploy.parameters]
stack_name = "node-app-dev"             # CloudFormation stack name (must be unique within your AWS account/region)
resolve_s3 = true                       # Auto-create/manage an S3 bucket for deployment artifacts
s3_prefix = "node-app-dev"              # Prefix / subfolder for artifacts inside the managed S3 bucket (not the bucket name)
region = "ap-southeast-1"               # AWS Region to deploy the stack into
confirm_changeset = true                # Ask for confirmation before applying the CloudFormation changeset
capabilities = "CAPABILITY_IAM"         # Acknowledge the stack will create IAM resources
disable_rollback = false                # Roll back the stack automatically if deployment fails
parameter_overrides = "Environment=dev Cpu=256 Memory=512 DesiredCount=1 ApiEndpoint=https://api.openweathermap.org ApiKey=your-api-key-here"
```

> `samconfig.toml` is gitignored so your API key stays local. Use `samconfig.toml.example` (tracked in git) as a reference.

**Purpose:** After configuring this file, you can simply run `sam deploy` without any flags — it reads all settings from here.

## Automated Deploy

Run the deploy script to handle the full deployment (infrastructure + app):

```bash
# Linux/macOS (first time only)
chmod +x .scripts/deploy.sh

# Run the script
./.scripts/deploy.sh
```

Windows (Git Bash or WSL):

```bash
bash .scripts/deploy.sh
```

With a specific environment:

```bash
./.scripts/deploy.sh --env staging
```

## Deployment Steps (Manual)

### 1. Build Docker Image

```bash
# Create nginx.conf from template
cp nginx.conf.example nginx.conf

# Build the Docker image
docker build -t node-app .
```

### 2. Configure Parameters

Edit `samconfig.toml` — set your AWS region, stack name, and API key:

```toml
[default.deploy.parameters]
stack_name = "node-app-dev"
region = "ap-southeast-1"
parameter_overrides = "Environment=dev Cpu=256 Memory=512 DesiredCount=1 ApiEndpoint=https://api.openweathermap.org ApiKey=your-actual-api-key"
```

### 3. Build SAM Template

```bash
sam build
```

### 4. Deploy Stack

```bash
# Option A: Use samconfig.toml (reads settings from the file)
sam deploy

# Option B: Guided deployment (interactive — overwrites samconfig.toml)
sam deploy --guided

# Option C: Deploy with inline parameter overrides
sam deploy \
  --parameter-overrides \
    Environment=dev \
    ApiKey="your-api-key" \
    ApiEndpoint="https://api.openweathermap.org"
```

### 5. Authenticate Docker to ECR

After the stack deploys, get the ECR URI from the outputs:

```bash
# Get ECR URI from stack outputs
ECR_URI=$(aws cloudformation describe-stacks \
  --stack-name node-app-dev \
  --query "Stacks[0].Outputs[?OutputKey=='ECRRepositoryURI'].OutputValue" \
  --output text)

# Authenticate Docker to ECR
aws ecr get-login-password --region <your-region> | \
  docker login --username AWS --password-stdin $ECR_URI
```

### 6. Push Image to ECR

```bash
# Tag the image
docker tag node-app:latest $ECR_URI:latest

# Push to ECR
docker push $ECR_URI:latest
```

### 7. Update ECS Service

Force a new deployment to pull the updated image:

```bash
# Get cluster and service names from outputs
CLUSTER=$(aws cloudformation describe-stacks \
  --stack-name node-app-dev \
  --query "Stacks[0].Outputs[?OutputKey=='ECSClusterName'].OutputValue" \
  --output text)

SERVICE=$(aws cloudformation describe-stacks \
  --stack-name node-app-dev \
  --query "Stacks[0].Outputs[?OutputKey=='ECSServiceName'].OutputValue" \
  --output text)

# Force new deployment
aws ecs update-service \
  --cluster $CLUSTER \
  --service $SERVICE \
  --force-new-deployment
```

### 8. Access the App

```bash
# Get task public IP
TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --query "taskArns[0]" --output text)

aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ARN \
  --query "tasks[0].attachments[0].details[?name=='privateIPv4Address'].value" --output text

# Open in browser
http://<PUBLIC_IP>
http://<PUBLIC_IP>/weather?q=manila
```

## Updating the App

```bash
# 1. Rebuild Docker image
docker build -t node-app .

# 2. Tag and push to ECR
docker tag node-app:latest $ECR_URI:latest
docker push $ECR_URI:latest

# 3. Force ECS service update
aws ecs update-service --cluster $CLUSTER --service $SERVICE --force-new-deployment
```

## Viewing Logs

```bash
# Open CloudWatch Logs
aws logs tail /ecs/dev-node-app --follow
```

Or via AWS Console:

1. Go to **CloudWatch** > **Log Groups**
2. Select `/ecs/dev-node-app`
3. Click on the latest log stream

## Cleanup

### Automated Cleanup

Run the cleanup script to delete all resources for an environment:

```bash
# Linux/macOS (first time only)
chmod +x .scripts/cleanup.sh

# Run the script
./.scripts/cleanup.sh
```

Windows (Git Bash or WSL):

```bash
bash .scripts/cleanup.sh
```

Delete a specific environment:

```bash
./.scripts/cleanup.sh --env staging
```

Delete all environments:

```bash
./.scripts/cleanup.sh --env all
```

### Manual Cleanup

Delete all resources created by the SAM stack:

```bash
sam delete
```

This will:

- Delete the ECS service and cluster
- Delete the task definition
- Delete the ECR repository
- Delete the VPC and networking resources
- Delete the IAM role
- Delete the Secrets Manager secrets
- Delete the CloudWatch log group

**Note:** `sam delete` will prompt for confirmation. Use `--no-prompts` to skip:

```bash
sam delete --no-prompts
```

To also remove local build artifacts:

```bash
rm -rf .aws-sam/
```

To remove local config files (if you no longer need them):

```bash
rm samconfig.toml
```

## Outputs

After deployment, the following outputs are available:

| Output                    | Description                           |
| ------------------------- | ------------------------------------- |
| `ECRRepositoryURI`        | ECR repository URI for pushing images |
| `ECSClusterName`          | ECS cluster name                      |
| `ECSServiceName`          | ECS service name                      |
| `TaskDefinitionArn`       | Task definition ARN                   |
| `VPCId`                   | VPC ID                                |
| `SecurityGroupId`         | Security group ID                     |
| `PublicSubnet1Id`         | Public subnet 1 ID                    |
| `PublicSubnet2Id`         | Public subnet 2 ID                    |
| `ApiEndpointSecretArn`    | API endpoint secret ARN               |
| `ApiKeySecretArn`         | API key secret ARN                    |
| `ECSTaskExecutionRoleArn` | IAM role ARN                          |

View outputs:

```bash
aws cloudformation describe-stacks \
  --stack-name node-app-dev \
  --query "Stacks[0].Outputs"
```

## Multi-Environment Deployment

Deploy to different environments:

```bash
# Dev
sam deploy --parameter-overrides Environment=dev

# Staging
sam deploy --parameter-overrides Environment=staging

# Production
sam deploy --parameter-overrides Environment=prod
```

Each environment gets its own isolated stack with separate resources.
