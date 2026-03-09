# OpenClaw EC2 Automation Instance — Design

**Date:** 2026-03-09
**Project:** ocs-automation
**Goal:** Self-hosted OpenClaw instance on AWS EC2 for open-chat-studio project automation

---

## Overview

A standalone AWS EC2 instance running OpenClaw, configured to automate open-chat-studio development tasks. It integrates with Slack and GitHub, and manages Claude Code sessions via ACP (Agent Client Protocol) for isolated, full-stack task execution.

---

## Architecture

### Infrastructure (Pulumi/Python)

- **EC2 t3.large** — Ubuntu 24.04, 100GB gp3 root EBS + 200GB gp3 data EBS volume (workspaces)
- **Elastic IP** — stable address for webhook endpoints
- **Security Group** — HTTPS (443) open for Slack/GitHub webhooks; all other inbound restricted
- **IAM Role** — SSM Session Manager access (no SSH keys), Secrets Manager read, S3 for artifacts
- **Secrets Manager** — Anthropic API key, Slack app tokens, GitHub App credentials

Access model: no SSH key pairs. All admin access via AWS SSM Session Manager.

---

## Project Structure

```
ocs-automation/
├── pyproject.toml              # Pulumi project, uv-managed
├── infra/
│   ├── __main__.py             # Pulumi entry point
│   ├── config.py               # Env config
│   ├── ec2.py                  # EC2 + SG + EIP + EBS + IAM
│   └── secrets.py              # Secrets Manager resources
├── scripts/
│   ├── bootstrap.sh            # EC2 user-data: Docker, OpenClaw, repo setup
│   └── deploy.sh               # Update/redeploy OpenClaw on running instance
├── openclaw/
│   ├── docker-compose.yml      # OpenClaw gateway container
│   ├── config/
│   │   └── workspace.json      # OpenClaw config (Slack, GitHub, ACP, skills)
│   └── skills/
│       └── ocs/                # Custom OpenClaw skill for OCS task routing
│           ├── skill.json
│           └── prompts/        # Task-specific Claude prompts
└── session/
    ├── Dockerfile              # Claude Code session container image
    └── docker-compose.yml      # Session stack: Django + Postgres + Redis + Playwright
```

---

## Session Container Model

Each Claude Code task runs in an isolated Docker Compose stack on the EC2 host.

**Session directory layout (per task):**
```
/data/sessions/session-<task-id>/
  app/        ← shallow clone of open-chat-studio
  postgres/   ← isolated Postgres data
  redis/      ← isolated Redis data
```

**Session lifecycle:**
1. OpenClaw receives task trigger (Slack, GitHub webhook, or cron)
2. Session manager creates directory, runs `docker compose up` (Postgres, Redis, Django migrations)
3. Claude Code launches in the session container via `acpx` (headless ACP client)
4. Claude Code executes task: can run tests, start dev server, run Playwright UI tests
5. On completion: results posted to Slack/GitHub; `docker compose down -v` cleans up

**Concurrency:** One session at a time (t3.large constraint). Tasks are queued. A lock file on the host enforces single-session execution.

---

## Task Routing

| Trigger | Source | Claude Code Task |
|---|---|---|
| `/ocs <prompt>` | Slack DM or channel | Ad-hoc open-ended task |
| PR opened/updated | GitHub webhook | Code review, post PR comment |
| CI failed | GitHub webhook | Log analysis, post triage to Slack/PR |
| `@openclaw work on #123` | Slack mention | Implement GitHub issue, open PR |
| `@openclaw review #123` | Slack mention | Issue triage, add labels/comments |
| `@openclaw audit architecture` | Slack mention | Generate issues from code review |
| Daily cron | OpenClaw cron skill | Incremental type-checking / long-running tasks |

---

## OpenClaw Configuration

- **Slack:** Socket Mode (app token + bot token); listens to DMs and `#ocs-automation` channel
- **GitHub:** GitHub App (fine-grained permissions: PRs, issues, actions read)
- **ACP:** `acpx` as the headless ACP client; Claude Code configured with open-chat-studio workspace skills

---

## Security Considerations

- All secrets in AWS Secrets Manager; loaded into containers at runtime via environment injection
- No credentials stored on disk or in version control
- EC2 instance has no inbound SSH; management via SSM only
- Claude Code sessions run as non-root inside containers
- Session containers do not have internet access beyond what's needed (GitHub, Anthropic API)

---

## Not In Scope (v1)

- Auto-scaling or multi-instance deployment
- Custom CI/CD for the automation instance itself (manual deploy via `deploy.sh`)
- Web UI for task management
- Per-user Slack workspaces (single workspace only)
