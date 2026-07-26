# Deploy Using Terraform

Deploy the Node.js app to AWS ECS Fargate using Terraform.

## Status

**Coming Soon**

This folder will contain Terraform configuration files for deploying the Node.js app to AWS ECS Fargate.

## Planned Resources

| Resource | Description |
|----------|-------------|
| `aws_vpc` | Virtual Private Cloud |
| `aws_subnet` | Public subnets |
| `aws_internet_gateway` | Internet access |
| `aws_security_group` | HTTP/HTTPS access |
| `aws_ecr_repository` | Docker image storage |
| `aws_ecs_cluster` | ECS Fargate cluster |
| `aws_ecs_task_definition` | Task configuration |
| `aws_ecs_service` | Running service |
| `aws_iam_role` | Task execution role |
| `aws_secretsmanager_secret` | API secrets |
| `aws_cloudwatch_log_group` | Container logs |

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) installed
- [AWS CLI](https://aws.amazon.com/cli/) configured
- [Docker](https://docs.docker.com/get-docker/) running locally
- Node.js 22+

## Learning Resources

- [Terraform AWS Provider Docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Terraform ECS Module](https://developer.hashicorp.com/terraform/tutorials/ecs-application-development)
- [AWS ECS Terraform Examples](https://github.com/hashicorp/terraform-provider-aws/tree/main/examples/ecs)
