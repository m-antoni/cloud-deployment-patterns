# AWS CLI Notes

Quick reference for inspecting the resources deployed by this folder's `node-app-dev` stack. All commands are read-only (`describe` / `list`) and use region `ap-southeast-1`.

> Scope: only resources owned by this pattern's stack. Other stacks in the account are unrelated.
>
> Commands are single-line so they work in both **PowerShell** and **Bash**.

## Your Resources

| Resource | Name |
| -------- | ---- |
| CloudFormation stack | `node-app-dev` |
| ECS cluster | `dev-node-app-cluster` |
| ECS service | `dev-node-app-service` |
| Task definition | `dev-node-app-task:<revision>` |
| ECR repository | `dev-node-app` |
| VPC | `<VPC_ID>` |
| Subnets | `<SUBNET_1>`, `<SUBNET_2>` |
| Security group | `<SECURITY_GROUP_ID>` |
| Internet gateway | `<INTERNET_GATEWAY_ID>` |
| Route table | `<ROUTE_TABLE_ID>` |
| IAM role | `dev-ECSTaskExecutionRoleSecrets` |
| Secrets Manager | `dev/node-app-api-key-<suffix>`, `dev/node-app-api-endpoint-<suffix>` |
| CloudWatch log group | `/ecs/dev-node-app` |

The stack re-creates the VPC, subnets, security group, gateway, route table, and Secrets Manager names from scratch on every deploy, so their physical IDs are random each time. Grab the current values with `describe-stack-resources` (below) — the placeholder values in these notes are `<...>` until you do.

## CloudFormation

```bash
# All stacks (non-deleted)
aws cloudformation list-stacks --region ap-southeast-1 --query "StackSummaries[?StackStatus!='DELETE_COMPLETE'].{Name:StackName,Status:StackStatus}" --output table

# Every resource owned by the stack, with physical names/ARNs (the master list)
# Run this after each deploy to get the current VPC/subnet/SG/secret IDs.
aws cloudformation describe-stack-resources --stack-name node-app-dev --region ap-southeast-1 --query "StackResources[].{Type:ResourceType,Name:PhysicalResourceId}" --output table

# Stack outputs (ECR URI, cluster, service, app URL)
aws cloudformation describe-stacks --stack-name node-app-dev --region ap-southeast-1 --query "Stacks[0].Outputs"
```

## ECS

```bash
# Cluster + service ARNs
aws ecs describe-clusters --clusters dev-node-app-cluster --region ap-southeast-1 --query "clusters[].clusterArn"
aws ecs describe-services --cluster dev-node-app-cluster --services dev-node-app-service --region ap-southeast-1 --query "services[].{Arn:serviceArn,Status:status,TaskDef:taskDefinition}"

# Which image is the service actually running (the post-rollback check)
aws ecs describe-services --cluster dev-node-app-cluster --services dev-node-app-service --region ap-southeast-1 --query "services[0].taskDefinition" --output text
aws ecs describe-task-definition --task-definition dev-node-app-task:<revision> --region ap-southeast-1 --query "taskDefinition.containerDefinitions[0].image" --output text

# Task definition revisions
aws ecs list-task-definitions --family-prefix dev-node-app-task --region ap-southeast-1
```

## ECR

```bash
# Repository info
aws ecr describe-repositories --repository-names dev-node-app --region ap-southeast-1 --query "repositories[].{Name:repositoryName,Arn:repositoryArn,Uri:repositoryUri}"

# Images with tags + push times (tags = rollback targets)
aws ecr describe-images --repository-name dev-node-app --region ap-southeast-1 --query "imageDetails[*].{Tags:imageTags,PushedAt:imagePushedAt}" --output table

# Lifecycle policy (keeps the last 10 images)
aws ecr get-lifecycle-policy --repository-name dev-node-app --region ap-southeast-1 --query "lifecyclePolicyText" --output text
```

## VPC & Networking

> Replace `<VPC_ID>`, `<SUBNET_1>`, `<SUBNET_2>`, `<SECURITY_GROUP_ID>`, `<INTERNET_GATEWAY_ID>`, `<ROUTE_TABLE_ID>` with the current values from `describe-stack-resources` — they change on every deploy.

```bash
aws ec2 describe-vpcs --vpc-ids <VPC_ID> --query "Vpcs[].VpcId"
aws ec2 describe-subnets --subnet-ids <SUBNET_1> <SUBNET_2> --query "Subnets[].{Id:SubnetId,Cidr:CidrBlock,AZ:AvailabilityZone}"
aws ec2 describe-security-groups --group-ids <SECURITY_GROUP_ID> --query "SecurityGroups[].{Id:GroupId,Name:GroupName}"
aws ec2 describe-internet-gateways --internet-gateway-ids <INTERNET_GATEWAY_ID> --query "InternetGateways[].InternetGatewayId"
aws ec2 describe-route-tables --route-table-ids <ROUTE_TABLE_ID> --query "RouteTables[].RouteTableId"
```

## IAM

```bash
aws iam get-role --role-name dev-ECSTaskExecutionRoleSecrets --query "Role.{Name:RoleName,Arn:Arn}"
aws iam list-attached-role-policies --role-name dev-ECSTaskExecutionRoleSecrets
```

## Secrets Manager

> The secret **names** get a random suffix on each deploy (e.g. `dev/node-app-api-key-<suffix>`). List them first to get the current name.

```bash
# Metadata only (safe) - list current secret names first
aws secretsmanager list-secrets --region ap-southeast-1 --query "SecretList[?starts_with(Name,'dev/')].{Name:Name,Arn:ARN}"
aws secretsmanager describe-secret --secret-id dev/node-app-api-key-<suffix> --region ap-southeast-1

# Value (prints the secret - run locally only, never commit this output)
aws secretsmanager get-secret-value --secret-id dev/node-app-api-key-<suffix> --region ap-southeast-1 --query "SecretString" --output text
```

## CloudWatch Logs

> `aws logs tail` is **AWS CLI v2 only** — on v1 (like `aws-cli/1.45.14`), use the two commands below.

```bash
# Log groups
aws logs describe-log-groups --log-group-name-prefix /ecs/dev-node-app --region ap-southeast-1 --query "logGroups[].{Name:logGroupName,Arn:arn}"

# 1) Find the most recent log stream
aws logs describe-log-streams --log-group-name /ecs/dev-node-app --region ap-southeast-1 --order-by LastEventTime --descending --max-items 1 --query "logStreams[0].logStreamName" --output text

# 2) Read the last N events from it (replace <STREAM> with the output of step 1)
aws logs get-log-events --log-group-name /ecs/dev-node-app --log-stream-name <STREAM> --region ap-southeast-1 --limit 50 --query "events[].message" --output text
```

> Don't paste `<STREAM>` literally — it's a placeholder. PowerShell reserves `<`, so either substitute the real stream name or use the one-liner below.

**PowerShell one-liner (finds the latest stream automatically):**

```powershell
$s = aws logs describe-log-streams --log-group-name /ecs/dev-node-app --region ap-southeast-1 --order-by LastEventTime --descending --max-items 1 --query "logStreams[0].logStreamName" --output text | Select-Object -First 1; aws logs get-log-events --log-group-name /ecs/dev-node-app --log-stream-name $s --region ap-southeast-1 --limit 50 --query "events[].message" --output text
```

## Rollback Helpers

```bash
# Available tags to roll back to (same as the ECR image tags)
aws ecr describe-images --repository-name dev-node-app --region ap-southeast-1 --query "imageDetails[].imageTags[]" --output text

# Current running tag
aws ecs describe-task-definition --task-definition dev-node-app-task:<revision> --region ap-southeast-1 --query "taskDefinition.containerDefinitions[0].image" --output text
```

## Safety

- These commands are read-only, but some (like `get-secret-value`) **print sensitive values** — run those locally, never paste into logs/issues/PRs.
- The stack always creates unique resources on deploy, so VPC/subnet/SG/gateway/route-table IDs and Secrets Manager suffixes **change on every deploy**. Re-run `describe-stack-resources` after each deploy to get the current values.
