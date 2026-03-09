import pulumi_aws as aws
from infra.config import make_name


def create_secrets() -> dict:
    """
    Create Secrets Manager secrets for OpenClaw.
    Values are set manually after deployment — never in code.

    To set a secret value after deploying:
        aws secretsmanager put-secret-value \\
            --secret-id ocs-automation/openclaw-env \\
            --secret-string "$(cat .env.prod)"
    """

    # Single secret containing full .env file for OpenClaw
    # Format: KEY=value lines (dotenv format)
    openclaw_env = aws.secretsmanager.Secret(
        make_name("openclaw-env"),
        name="ocs-automation/openclaw-env",
        description="OpenClaw .env file: Anthropic, Slack, GitHub credentials",
        tags={"Project": "ocs-automation"},
    )

    # GitHub App private key (PEM, stored separately as it's large)
    github_app_key = aws.secretsmanager.Secret(
        make_name("github-app-key"),
        name="ocs-automation/github-app-key",
        description="GitHub App private key PEM for OCS automation",
        tags={"Project": "ocs-automation"},
    )

    return {
        "openclaw_env": openclaw_env,
        "github_app_key": github_app_key,
    }
