# __main__.py
import pulumi
import pulumi_aws as aws
from infra.config import cfg
from infra.iam import create_instance_profile
from infra.security_group import create_security_group
from infra.ec2 import create_instance
from infra.secrets import create_secrets
from infra.s3 import create_artifacts_bucket

# Look up default VPC
vpc = aws.ec2.get_vpc(default=True)

# Domain (required — set with: pulumi config set domain <your-domain>)
domain = cfg.require("domain")

# S3 artifacts bucket
bucket = create_artifacts_bucket()

# IAM
profile = create_instance_profile(artifacts_bucket_name=bucket.bucket)

# Networking
sg = create_security_group(vpc_id=vpc.id)

# Secrets
secrets = create_secrets()

# EC2
resources = create_instance(
    security_group_id=sg.id,
    instance_profile_name=profile.name,
    domain=domain,
)

# Outputs
pulumi.export("instance_id", resources["instance"].id)
pulumi.export("public_ip", resources["eip"].public_ip)
pulumi.export("artifacts_bucket_name", bucket.bucket)
pulumi.export("openclaw_env_secret_arn", secrets["openclaw_env"].arn)
pulumi.export("github_app_key_secret_arn", secrets["github_app_key"].arn)
