# Cloud Deployment Patterns

Hands-on guide: one Node.js api deployed via AWS Console, SAM, and Terraform

## Tech Stack

| Tech                | Description                                            |
| ------------------- | ------------------------------------------------------ |
| Node.js             | JavaScript runtime                                     |
| Express             | Web framework for building REST APIs                   |
| Nginx               | Reverse proxy (load balancing, caching, SSL available) |
| Docker              | Containerization platform                              |
| AWS ECR             | Elastic Container Registry - stores Docker images      |
| AWS ECS             | Elastic Container Service - runs containers            |
| AWS Fargate         | Serverless compute engine for ECS                      |
| AWS Secrets Manager | Stores and manages secrets like API keys               |
| AWS IAM             | Manages access roles and permissions                   |
| AWS VPC             | Virtual Private Cloud - isolated network for resources |
| AWS CLI             | Command-line tool for managing AWS services            |
| GitHub Actions      | CI/CD — automates deploy/cleanup for each deployment pattern |

## Deployment Methods

| Method      | Description                                                               | Tool Type            |
| ----------- | ------------------------------------------------------------------------- | -------------------- |
| AWS Console | Manual deployment via the AWS Management Console — click-through UI setup | Manual               |
| AWS SAM     | Infrastructure-as-code using AWS SAM and CloudFormation                   | IaC (AWS-native)     |
| Terraform   | Infrastructure-as-code using Terraform — multi-cloud, state-managed       | IaC (Cloud-agnostic) |

## Architecture

```
[ Docker Build ] ──▶ [ ECR Repo ] ──▶ [ Task Definition ]
                                                │
            ┌───────────────────────────────────┘
            ▼
┌── VPC (10.0.0.0/16) ────────────────────────────────────┐
│                                                         │
│ ┌── ECS Fargate Cluster ──────────────────────────────┐ │
│ │                                                     │ │
│ │  [ Task: Nginx :80 → Node.js :5000 ]                │ │
│ │                                                     │ │
│ └─────────────────────────────────────────────────────┘ │
│                                                         │
│  Public Subnets ──▶ Security Group ──▶ ENI             │
└─────────────────────────────────────────────────────────┘
```

## Project Structure

```
deploy-patterns/
├── README.md                              # This file (overview)
├── .github/workflows/                     # GitHub Actions CI/CD pipelines (one per pattern)
│   ├── dev-aws-sam.yml                     # Deploy/cleanup for the SAM app
│   └── dev-aws-sam-rollback.yml            # Manual rollback for the SAM app
├── 01-deploy-using-aws-console/           # Manual deployment via AWS Console
│   ├── README.md                          # Step-by-step console guide
│   ├── src/                               # App source code
│   ├── Dockerfile
│   └── ...
├── 02-deploy-using-aws-sam/               # AWS SAM (IaC) deployment
│   ├── README.md                          # SAM deployment guide
│   ├── src/                               # App source code
│   ├── template.yaml                      # SAM/CloudFormation template
│   ├── samconfig.toml                     # SAM CLI config
│   ├── Dockerfile
│   └── ...
└── 03-deploy-using-terraform/             # Terraform (IaC) deployment
    ├── README.md                          # Coming soon
    ├── src/                               # App source code
    ├── Dockerfile
    └── ...
```

## Deployment Guides

| Method                                             | Description                                                        | Best For                          |
| -------------------------------------------------- | ------------------------------------------------------------------ | --------------------------------- |
| [AWS&nbsp;Console](./01-deploy-using-aws-console/) | Manual deployment via AWS Management Console UI                    | Learning, one-off deployments     |
| [AWS&nbsp;SAM](./02-deploy-using-aws-sam/)         | IaC using AWS SAM and CloudFormation                               | Automated, repeatable deployments |
| [Terraform](./03-deploy-using-terraform/)          | IaC using Terraform — multi-cloud, state-managed **(In Progress)** | Advanced IaC, multi-cloud         |

## CI/CD with GitHub Actions

This repo uses GitHub Actions to automate deployment and cleanup for each deployment pattern. Workflows live in `.github/workflows/` — one file per pattern:

| Workflow file | Pattern | Status |
| ------------- | ------- | ------ |
| `dev-aws-sam.yml` | AWS SAM (folder `02-deploy-using-aws-sam/`) | ✅ Implemented |
| `dev-aws-sam-rollback.yml` | AWS SAM — manual rollback to a pinned image tag | ✅ Implemented |
| _(planned)_ | AWS Console (folder `01-deploy-using-aws-console/`) | Planned |
| _(planned)_ | Terraform (folder `03-deploy-using-terraform/`) | Planned |

Every workflow follows the same conventions:

- **Triggers** — pushes to a pattern-specific branch (e.g. `release/dev-aws-sam`) with a path filter, plus a manual **Run workflow** button.
- **Mode** — a `mode` input (`deploy` | `cleanup`). Cleanup can also be triggered by pushing a commit whose message contains `--cleanup`.
- **Rollback** — deploys pin the image tag (git SHA); if the new deployment fails, the deploy script automatically reverts to the previous tag. A separate manual rollback workflow redeploys any pinned tag on demand.
- **Notifications** — every run emails started + SUCCESS/FAILED results with a link to the run.
- **Secrets** — scoped to a per-pattern GitHub Environment (e.g. `release-dev-aws-sam`) holding AWS credentials and notification SMTP settings.

The [AWS SAM workflow](./02-deploy-using-aws-sam/#github-actions-cicd) is the reference implementation — the other patterns will mirror its structure.

## Prerequisites

- Node.js 22+
- Docker
- AWS CLI configured
- Additional tools depending on deployment method (see each folder's README)

## Local Development

```bash
# Navigate to any deployment folder (they all contain the same app)
cd 01-deploy-using-aws-console

# Install dependencies
npm install

# Run in development mode
npm run dev
```

## API Usage

```
GET /weather?q=manila
```

### OpenWeatherMap API Setup

1. Go to [https://openweathermap.org/api](https://openweathermap.org/api)
2. Click **Sign Up** and create a free account
3. Verify your email address
4. Go to **API Keys** tab in your account dashboard
5. Copy your default API key (or click **Generate** to create a new one)
6. The free tier includes:
   - Current weather data
   - 1,000 API calls/day
   - No credit card required

> **Note:** API keys take ~10 minutes to activate after creation.

## Docker

```bash
# Navigate to any deployment folder
cd 01-deploy-using-aws-console

# Create nginx.conf from template
cp nginx.conf.example nginx.conf

# Build and run
docker build -t node-app .
docker run -p 80:80 -e API_ENDPOINT=https://api.openweathermap.org -e API_KEY=<API_KEY> node-app
```

---

### Author

**Michael B. Antoni**

- **Email:** michaelantoni.tech@gmail.com
- **Website:** [https://michaelantoni.vercel.app](https://michaelantoni.vercel.app)
- **LinkedIn:** [https://linkedin.com/in/m-antoni](https://linkedin.com/in/m-antoni)
