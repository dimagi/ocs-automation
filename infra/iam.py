# infra/iam.py
import json
import pulumi
import pulumi_aws as aws
from infra.config import make_name, environment, PROJECT_NAME


def create_instance_profile(artifacts_bucket_name: pulumi.Output) -> aws.iam.InstanceProfile:
    """EC2 IAM role with SSM, Secrets Manager, and S3 permissions."""

    identity = aws.get_caller_identity()
    region_output = aws.get_region()

    role = aws.iam.Role(
        make_name("role"),
        assume_role_policy=json.dumps({
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "ec2.amazonaws.com"},
                "Action": "sts:AssumeRole",
            }],
        }),
        tags={"Environment": environment, "Project": PROJECT_NAME},
    )

    # SSM access for session manager (no SSH needed)
    aws.iam.RolePolicyAttachment(
        make_name("ssm-policy"),
        role=role.name,
        policy_arn="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    )

    # Read secrets from Secrets Manager — scoped to actual account and region
    secrets_policy_doc = pulumi.Output.all(identity.account_id, region_output.name).apply(
        lambda args: json.dumps({
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
                "Resource": f"arn:aws:secretsmanager:{args[1]}:{args[0]}:secret:{PROJECT_NAME}/*",
            }],
        })
    )

    aws.iam.RolePolicy(
        make_name("secrets-policy"),
        role=role.id,
        policy=secrets_policy_doc,
    )

    # S3 for session artifacts — reference actual bucket output
    s3_policy_doc = artifacts_bucket_name.apply(
        lambda bucket_name: json.dumps({
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket"],
                "Resource": [
                    f"arn:aws:s3:::{bucket_name}",
                    f"arn:aws:s3:::{bucket_name}/*",
                ],
            }],
        })
    )

    aws.iam.RolePolicy(
        make_name("s3-policy"),
        role=role.id,
        policy=s3_policy_doc,
    )

    profile = aws.iam.InstanceProfile(
        make_name("instance-profile"),
        role=role.name,
    )

    return profile
