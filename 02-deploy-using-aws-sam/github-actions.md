# GitHub Actions (CI/CD)

> CI/CD for this folder. Back to the [main guide](./README.md).

Two workflows (at the repo root — GitHub only reads `.github/workflows/` there):

- `dev-aws-sam.yml` — **Deploy** or **Cleanup** (auto on push, or manual)
- `dev-aws-sam-rollback.yml` — **Rollback** to a specific image tag (manual only)

## Triggers

| Trigger | Runs |
| ------- | ---- |
| Push to `release/dev-aws-sam` (files under `02-deploy-using-aws-sam/**` changed) | Deploy |
| Same push, but commit message is exactly `--cleanup` | Cleanup |
| Actions → **Run workflow** → `mode: deploy` / `mode: cleanup` | Deploy / Cleanup |
| Actions → **Run workflow** (rollback) → `environment` + `tag` | Rollback |

## Required Secrets

In repo **Settings → Environments → `release-dev-aws-sam` → Environment secrets**:

`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` (`ap-southeast-1`), `OPENWEATHER_API_KEY`, `MAIL_SMTP_SERVER` (`smtp.gmail.com`), `MAIL_USERNAME`, `MAIL_PASSWORD`, `MAIL_FROM`, `MAIL_TO`.

## How to Use

### 1. Deploy

```bash
git add .
git commit -m "fix weather endpoint"
git push origin release/dev-aws-sam
```

Manual: **Actions** → **Run workflow** → `mode: deploy`.

Deploys pin the image to your git SHA, so every version can be rolled back to later. If the deploy never becomes healthy, it **auto-reverts to the previous tag**.

### 2. Cleanup (destroys the whole stack)

```bash
git commit -m "--cleanup"
git push origin release/dev-aws-sam
```

Manual: **Actions** → **Run workflow** → `mode: cleanup`.

> **Gotchas:** the commit must also change a file under `02-deploy-using-aws-sam/**`, and the message must be exactly `--cleanup` — anything else (e.g. `--cleanup aws cloud stack`) runs a **deploy**. On failure the stack is left intact; recover via [Manual Cleanup](./README.md#manual-cleanup).

### 3. Rollback

**Actions** → **Run workflow** (rollback) → `environment: dev`, `tag: <git-sha or latest>`.

Locally:

```bash
./.scripts/rollback.sh --env dev --tag <git-sha>     # --manual skips auto-revert
.scripts\rollback.ps1 -Env dev -Tag <git-sha>        # Windows
```

List available tags:

```bash
aws ecr describe-images --repository-name dev-node-app --region ap-southeast-1 \
  --query "imageDetails[*].imageTags" --output json
```

> ECR keeps the last 10 images (lifecycle policy in `template.yaml`) = the last 10 deploys. Auto-rollback needs a previous deploy to exist.

## Email Notifications

Two emails to `MAIL_TO` per run: **Started** and **Result** (`SUCCESS`/`FAILED` in the subject + run link).

## How It Works

- `samconfig.toml` / `nginx.conf` are gitignored (hold secrets) — CI regenerates them from the `*.example` files with `confirm_changeset`/`fail_on_empty_changeset` disabled so `sam deploy` runs non-interactively.
- `deploy.sh` builds + pushes the image to ECR as `:latest` and `:<git-sha>`, scales the service to 1 task, then hands off to `rollback.sh`.
- `rollback.sh` deploys the pinned tag via `sam deploy --parameter-overrides ImageTag=<tag>`, waits for the ECS deployment to go healthy, and auto-reverts on failure. CloudFormation also auto-rolls-back failed stack updates.
- Cleanup runs `.scripts/cleanup.sh --env dev --yes` (`--yes` = no interactive prompt in CI).
