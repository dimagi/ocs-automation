import json
import pulumi_aws as aws
from infra.config import make_name, environment


def create_instance_profile():
    """EC2 IAM role with SSM, Secrets Manager, and S3 permissions."""

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
        tags={"Environment": environment, "Project": "ocs-automation"},
    )

    # SSM access for session manager (no SSH needed)
    aws.iam.RolePolicyAttachment(
        make_name("ssm-policy"),
        role=role.name,
        policy_arn="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    )

    # Read secrets from Secrets Manager
    aws.iam.RolePolicy(
        make_name("secrets-policy"),
        role=role.id,
        policy=json.dumps({
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
                "Resource": "arn:aws:secretsmanager:*:*:secret:ocs-automation/*",
            }],
        }),
    )

    # S3 for session artifacts (logs, outputs)
    aws.iam.RolePolicy(
        make_name("s3-policy"),
        role=role.id,
        policy=json.dumps({
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket"],
                "Resource": [
                    "arn:aws:s3:::ocs-automation-artifacts",
                    "arn:aws:s3:::ocs-automation-artifacts/*",
                ],
            }],
        }),
    )

    profile = aws.iam.InstanceProfile(
        make_name("instance-profile"),
        role=role.name,
    )

    return profile
