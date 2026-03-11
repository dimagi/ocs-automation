# tasks.py
# Invoke tasks for ocs-automation ops.
# Usage: uv run inv <task>    or    uv run inv --list
import json
import subprocess
import sys
import time

from invoke import task, Context

REGION = "us-east-1"
BUCKET = "ocs-automation-artifacts"
OP_PREFIX = "op run --env-file=.pulumi.env --"

# ANSI color helpers
_BOLD = "\033[1m"
_CYAN = "\033[36m"
_GREEN = "\033[32m"
_YELLOW = "\033[33m"
_RED = "\033[31m"
_DIM = "\033[2m"
_RESET = "\033[0m"
_PREFIX = f"{_BOLD}{_CYAN}[ocs]{_RESET}"


def _info(msg: str):
    print(f"{_PREFIX} {msg}")


def _success(msg: str):
    print(f"{_PREFIX} {_GREEN}{msg}{_RESET}")


def _warn(msg: str):
    print(f"{_PREFIX} {_YELLOW}{msg}{_RESET}")


def _error(msg: str):
    print(f"{_PREFIX} {_RED}{msg}{_RESET}", file=sys.stderr)


def _step(msg: str):
    print(f"{_PREFIX} {_DIM}{msg}{_RESET}")


def _pulumi_output(c: Context, key: str) -> str:
    """Get a single Pulumi stack output value."""
    result = c.run(f"{OP_PREFIX} pulumi stack output {key}", hide=True, warn=True)
    if result.failed:
        _error(f"Failed to get pulumi output '{key}'. Is the stack initialized?")
        sys.exit(1)
    return result.stdout.strip()


def _instance_id(c: Context) -> str:
    return _pulumi_output(c, "instance_id")


# ---------------------------------------------------------------------------
# Infrastructure
# ---------------------------------------------------------------------------


@task(help={"yes": "Skip confirmation prompt"})
def up(c, yes=False):
    """Deploy or update infrastructure via Pulumi."""
    flag = " --yes" if yes else ""
    c.run(f"{OP_PREFIX} pulumi up{flag}", pty=True)


@task
def outputs(c):
    """Show Pulumi stack outputs."""
    c.run(f"{OP_PREFIX} pulumi stack output", pty=True)


@task
def preview(c):
    """Preview infrastructure changes without applying."""
    c.run(f"{OP_PREFIX} pulumi preview", pty=True)


@task
def rebuild(c):
    """Terminate the EC2 instance, refresh Pulumi state, and recreate it."""
    instance_id = _instance_id(c)
    _info(f"Terminating instance {_BOLD}{instance_id}{_RESET}...")
    result = c.run(
        f"aws ec2 terminate-instances --instance-ids {instance_id} --region {REGION}",
        pty=True,
        warn=True,
    )
    if result.ok:
        _step("Waiting for instance to terminate...")
        c.run(
            f"aws ec2 wait instance-terminated --instance-ids {instance_id} --region {REGION}",
            pty=True,
        )
        _success("Instance terminated.")
    else:
        _warn("Instance already gone, skipping wait.")
    _info("Refreshing Pulumi state and recreating instance...")
    c.run(
        f'{OP_PREFIX} bash -c "pulumi refresh --yes --skip-preview && pulumi up --yes --skip-preview"',
        pty=True,
    )
    _success("Rebuild complete.")


# ---------------------------------------------------------------------------
# Deploy config/code to running instance
# ---------------------------------------------------------------------------


@task
def deploy(c):
    """Sync config, skills, and session files to the running instance via SSM."""
    instance_id = _instance_id(c)
    _info(f"Deploying to {_BOLD}{instance_id}{_RESET}...")
    c.run(f"./scripts/deploy.sh {instance_id}", pty=True)
    _success("Deploy complete.")


# ---------------------------------------------------------------------------
# SSH / SSM
# ---------------------------------------------------------------------------


@task
def ssh(c):
    """Open an SSM session to the EC2 instance."""
    instance_id = _instance_id(c)
    _info(f"Connecting to {_BOLD}{instance_id}{_RESET}...")
    c.run(
        f"aws ssm start-session --target {instance_id} --region {REGION}"
        f" --document-name AWS-StartInteractiveCommand"
        f" --parameters command='bash -l'",
        pty=True,
    )


# ---------------------------------------------------------------------------
# Logs & status
# ---------------------------------------------------------------------------


@task(help={"follow": "Tail logs continuously", "lines": "Number of lines to show"})
def logs(c, follow=False, lines=100):
    """Show openclaw-gateway container logs via SSM."""
    instance_id = _instance_id(c)
    tail = "-f" if follow else f"--tail {lines}"
    _step("Fetching gateway logs...")
    _ssm_run(c, instance_id, f"cd /data/openclaw && docker compose logs {tail} openclaw-gateway")


@task
def status(c):
    """Show container status on the EC2 instance."""
    instance_id = _instance_id(c)
    _step("Fetching container status...")
    _ssm_run(c, instance_id, "cd /data/openclaw && docker compose ps && echo '---' && docker ps --filter name=session --format 'table {{{{.Names}}}}\\t{{{{.Status}}}}\\t{{{{.RunningFor}}}}'")


@task
def health(c):
    """Run the gateway health check."""
    instance_id = _instance_id(c)
    _step("Running health check...")
    _ssm_run(c, instance_id, "cd /data/openclaw && docker compose run --rm openclaw-cli doctor")


# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------


@task(help={"env_file": "Path to .env.prod file (default: .env.prod)"})
def push_secrets(c, env_file=".env.prod"):
    """Upload .env.prod to AWS Secrets Manager."""
    c.run(
        f'aws secretsmanager put-secret-value'
        f' --secret-id ocs-automation/openclaw-env'
        f' --secret-string "$(cat {env_file})"'
        f' --region {REGION}',
        pty=True,
    )
    _success(f"Secrets updated from {env_file}")


@task(help={"pem_file": "Path to GitHub App PEM file"})
def push_github_key(c, pem_file):
    """Upload GitHub App private key to AWS Secrets Manager."""
    c.run(
        f'aws secretsmanager put-secret-value'
        f' --secret-id ocs-automation/github-app-key'
        f' --secret-string "$(cat {pem_file})"'
        f' --region {REGION}',
        pty=True,
    )
    _success(f"GitHub App key updated from {pem_file}")


# ---------------------------------------------------------------------------
# Lint
# ---------------------------------------------------------------------------


@task
def lint(c):
    """Run ruff check and format."""
    c.run("uv run ruff check .", pty=True, warn=True)
    c.run("uv run ruff format --check .", pty=True, warn=True)


@task
def fmt(c):
    """Auto-fix lint issues and format code."""
    c.run("uv run ruff check --fix .", pty=True, warn=True)
    c.run("uv run ruff format .", pty=True)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _ssm_run(c: Context, instance_id: str, command: str):
    """Run a command on the EC2 instance via SSM and stream output."""
    result = c.run(
        f"aws ssm send-command"
        f" --instance-ids {instance_id}"
        f' --document-name "AWS-RunShellScript"'
        f" --region {REGION}"
        f" --parameters 'commands=[\"{command}\"]'"
        f" --query Command.CommandId"
        f" --output text",
        hide=True,
        warn=True,
    )
    if result.failed:
        stderr = result.stderr.strip() if result.stderr else ""
        stdout = result.stdout.strip() if result.stdout else ""
        detail = stderr or stdout or "(no output)"
        _error(f"SSM send-command failed: {detail}")
        sys.exit(1)

    command_id = result.stdout.strip()

    for _ in range(60):
        time.sleep(2)
        poll = c.run(
            f"aws ssm get-command-invocation"
            f" --command-id {command_id}"
            f" --instance-id {instance_id}"
            f" --region {REGION}"
            f" --output json",
            hide=True,
            warn=True,
        )
        if poll.failed:
            continue
        data = json.loads(poll.stdout)
        cmd_status = data.get("Status", "")
        if cmd_status in ("Success", "Failed", "Cancelled", "TimedOut"):
            stdout = data.get("StandardOutputContent", "").strip()
            stderr = data.get("StandardErrorContent", "").strip()
            if stdout:
                print(stdout)
            if stderr:
                print(stderr, file=sys.stderr)
            if cmd_status != "Success":
                _error(f"Command {cmd_status}")
                sys.exit(1)
            return

    _error("Timed out waiting for SSM command")
    sys.exit(1)
