# tasks.py
# Invoke tasks for ocs-automation ops.
# Usage: uv run inv <task>    or    uv run inv --list
import json
import os
import shlex
import sys
import time

from invoke import Context, task

REGION = "us-east-1"
DEFAULT_AWS_PROFILE = "ocs-misc"

if not os.environ.get("AWS_PROFILE"):
    os.environ["AWS_PROFILE"] = DEFAULT_AWS_PROFILE
    _APPLIED_DEFAULT_PROFILE = True
else:
    _APPLIED_DEFAULT_PROFILE = False
BUCKET = "ocs-automation-prod-artifacts"
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


def _print_profile_notice():
    global _APPLIED_DEFAULT_PROFILE
    if _APPLIED_DEFAULT_PROFILE:
        print(
            f"{_PREFIX} {_YELLOW}AWS_PROFILE not set — using default"
            f" '{DEFAULT_AWS_PROFILE}'{_RESET}"
        )
        _APPLIED_DEFAULT_PROFILE = False  # only print once per invocation


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
    _print_profile_notice()
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
    _print_profile_notice()
    flag = " --yes" if yes else ""
    c.run(f"{OP_PREFIX} pulumi up{flag}", pty=True)
    _warn(
        "If the Elastic IP changed, update DNS for your domain to point to the"
        " new IP. Check with: uv run inv outputs"
    )


@task
def outputs(c):
    """Show Pulumi stack outputs."""
    _print_profile_notice()
    c.run(f"{OP_PREFIX} pulumi stack output", pty=True)


@task
def preview(c):
    """Preview infrastructure changes without applying."""
    _print_profile_notice()
    c.run(f"{OP_PREFIX} pulumi preview", pty=True)


@task
def rebuild(c):
    """Terminate the EC2 instance, refresh Pulumi state, and recreate it."""
    instance_id = _instance_id(c)
    _info(f"Terminating instance {_BOLD}{instance_id}{_RESET}...")
    result = c.run(
        f"aws ec2 terminate-instances --instance-ids {shlex.quote(instance_id)} --region {REGION}",
        pty=True,
        warn=True,
    )
    if result.ok:
        _step("Waiting for instance to terminate...")
        c.run(
            f"aws ec2 wait instance-terminated"
            f" --instance-ids {shlex.quote(instance_id)} --region {REGION}",
            pty=True,
        )
        _success("Instance terminated.")
    else:
        _warn("Instance already gone, skipping wait.")
    _info("Refreshing Pulumi state and recreating instance...")
    c.run(
        f"{OP_PREFIX} bash -c"
        f' "pulumi refresh --yes --skip-preview && pulumi up --yes --skip-preview"',
        pty=True,
    )
    _success("Rebuild complete.")
    _warn(
        "The Elastic IP has changed — update DNS for your domain to point to"
        " the new IP. Check with: uv run inv outputs"
    )


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


@task(help={"root": "Login as root instead of openclaw user"})
def ssh(c, root=False):
    """Open an SSM session to the EC2 instance."""
    instance_id = _instance_id(c)
    if root:
        cmd = "sudo bash -l"
    else:
        cmd = "sudo su -s /bin/bash - openclaw"
    _info(f"Connecting to {_BOLD}{instance_id}{_RESET}...")
    c.run(
        f"aws ssm start-session --target {instance_id} --region {REGION}"
        f" --document-name AWS-StartInteractiveCommand"
        f" --parameters command='{cmd}'",
        pty=True,
    )


# ---------------------------------------------------------------------------
# Logs & status
# ---------------------------------------------------------------------------


@task(help={"follow": "Tail logs continuously", "lines": "Number of lines to show"})
def logs(c, follow=False, lines=100):
    """Show openclaw-gateway logs via SSM."""
    instance_id = _instance_id(c)
    tail = "-f" if follow else f"-n {lines}"
    _step("Fetching gateway logs...")
    _ssm_run(c, instance_id, f"journalctl -u openclaw-gateway {tail} --no-pager")


@task
def status(c):
    """Show service and session status on the EC2 instance."""
    instance_id = _instance_id(c)
    _step("Fetching status...")
    _ssm_run(
        c,
        instance_id,
        "systemctl status openclaw-gateway caddy postgresql --no-pager -l 2>/dev/null; "
        "echo '--- Sessions ---'; "
        "docker ps --filter name=session"
        " --format 'table {{{{.Names}}}}\\t{{{{.Status}}}}\\t{{{{.RunningFor}}}}'",
    )


@task
def health(c):
    """Run the gateway health check."""
    instance_id = _instance_id(c)
    _step("Running health check...")
    _ssm_run(c, instance_id, "openclaw doctor")


@task
def restart(c):
    """Restart the openclaw-gateway service."""
    instance_id = _instance_id(c)
    _step("Restarting openclaw-gateway...")
    _ssm_run(c, instance_id, "systemctl restart openclaw-gateway")
    _success("Gateway restarted.")


# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------


@task(help={"env_file": "Path to .env.prod file (default: .env.prod)"})
def push_secrets(c, env_file=".env.prod"):
    """Upload .env.prod to AWS Secrets Manager."""
    _print_profile_notice()
    quoted_file = shlex.quote(env_file)
    c.run(
        f"aws secretsmanager put-secret-value"
        f" --secret-id ocs-automation/openclaw-env"
        f" --secret-string \"$(cat {quoted_file})\""
        f" --region {REGION}",
        pty=True,
    )
    _success(f"Secrets updated from {env_file}")


@task(help={"pem_file": "Path to GitHub App PEM file"})
def push_github_key(c, pem_file):
    """Upload GitHub App private key to AWS Secrets Manager."""
    _print_profile_notice()
    quoted_file = shlex.quote(pem_file)
    c.run(
        f"aws secretsmanager put-secret-value"
        f" --secret-id ocs-automation/github-app-key"
        f" --secret-string \"$(cat {quoted_file})\""
        f" --region {REGION}",
        pty=True,
    )
    _success(f"GitHub App key updated from {pem_file}")


# ---------------------------------------------------------------------------
# Backup / Restore
# ---------------------------------------------------------------------------


@task
def backup(c):
    """Trigger S3 backup on the instance."""
    instance_id = _instance_id(c)
    _step("Running backup...")
    _ssm_run(c, instance_id, "bash /opt/ocs-automation/scripts/backup-to-s3.sh")
    _success("Backup complete.")


@task(help={"timestamp": "Backup timestamp to restore (default: latest)"})
def restore(c, timestamp="latest"):
    """Restore from S3 backup."""
    instance_id = _instance_id(c)
    _step(f"Restoring from backup ({timestamp})...")
    cmd = f"bash /opt/ocs-automation/scripts/restore-from-s3.sh backups/{timestamp}"
    _ssm_run(c, instance_id, cmd)
    _success("Restore complete.")


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
    quoted_id = shlex.quote(instance_id)
    quoted_cmd = json.dumps([command])
    result = c.run(
        f"aws ssm send-command"
        f" --instance-ids {quoted_id}"
        f' --document-name "AWS-RunShellScript"'
        f" --region {REGION}"
        f" --parameters commands={shlex.quote(quoted_cmd)}"
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
            f" --command-id {shlex.quote(command_id)}"
            f" --instance-id {quoted_id}"
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
