import pulumi_aws as aws
from infra.config import make_name


def create_security_group(vpc_id: str) -> aws.ec2.SecurityGroup:
    """
    Security group for the OpenClaw EC2 instance.
    - HTTPS (443) open for Slack/GitHub webhooks
    - No SSH — access exclusively via SSM Session Manager
    - All outbound allowed
    """
    sg = aws.ec2.SecurityGroup(
        make_name("sg"),
        vpc_id=vpc_id,
        description="OpenClaw automation instance",
        ingress=[
            # HTTPS for Slack/GitHub webhooks
            aws.ec2.SecurityGroupIngressArgs(
                protocol="tcp",
                from_port=443,
                to_port=443,
                cidr_blocks=["0.0.0.0/0"],
                description="HTTPS for webhooks",
            ),
            # No SSH rule — use SSM Session Manager instead
        ],
        egress=[
            aws.ec2.SecurityGroupEgressArgs(
                protocol="-1",
                from_port=0,
                to_port=0,
                cidr_blocks=["0.0.0.0/0"],
                description="All outbound",
            ),
        ],
        tags={"Name": make_name("sg")},
    )
    return sg
