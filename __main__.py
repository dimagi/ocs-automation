import pulumi
import pulumi_aws as aws
from infra.iam import create_instance_profile
from infra.security_group import create_security_group
from infra.ec2 import create_instance
from infra.secrets import create_secrets

# Look up default VPC
vpc = aws.ec2.get_vpc(default=True)

# IAM
profile = create_instance_profile()

# Networking
sg = create_security_group(vpc_id=vpc.id)

# Secrets
secrets = create_secrets()

# EC2
resources = create_instance(
    security_group_id=sg.id,
    instance_profile_name=profile.name,
)

# Outputs
pulumi.export("instance_id", resources["instance"].id)
pulumi.export("public_ip", resources["eip"].public_ip)
pulumi.export("data_volume_id", resources["data_volume"].id)
pulumi.export("openclaw_env_secret_arn", secrets["openclaw_env"].arn)
pulumi.export("github_app_key_secret_arn", secrets["github_app_key"].arn)
