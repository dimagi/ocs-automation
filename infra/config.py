# infra/config.py
import pulumi
import pulumi_aws as aws

cfg = pulumi.Config()
aws_cfg = pulumi.Config("aws")

PROJECT_NAME = "ocs-automation"

# Stack-level settings
environment = cfg.get("environment") or "prod"
region = aws_cfg.get("region") or "ap-southeast-2"

# Instance settings
instance_type = cfg.get("instance_type") or "t3.large"


def make_name(resource: str) -> str:
    return f"{PROJECT_NAME}-{environment}-{resource}"
