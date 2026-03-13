# infra/ec2.py
import pathlib
from typing import TypedDict

import pulumi
import pulumi_aws as aws
from infra.config import make_name, instance_type, PROJECT_NAME


class InstanceResources(TypedDict):
    instance: aws.ec2.Instance
    eip: aws.ec2.Eip


def create_instance(
    security_group_id: pulumi.Output,
    instance_profile_name: pulumi.Output,
    domain: str,
) -> InstanceResources:
    """
    EC2 instance for OpenClaw.
    - Ubuntu 24.04 LTS (ap-southeast-2)
    - 150GB gp3 root volume
    - SSM-managed, no SSH key required
    """

    ami = aws.ec2.get_ami(
        most_recent=True,
        owners=["099720109477"],  # Canonical
        filters=[
            aws.ec2.GetAmiFilterArgs(
                name="name",
                values=["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"],
            ),
            aws.ec2.GetAmiFilterArgs(name="virtualization-type", values=["hvm"]),
        ],
    )

    bootstrap_path = pathlib.Path(__file__).parent.parent / "scripts" / "bootstrap.sh"
    user_data = bootstrap_path.read_text().replace("__DOMAIN__", domain)

    instance = aws.ec2.Instance(
        make_name("instance"),
        ami=ami.id,
        instance_type=instance_type,
        iam_instance_profile=instance_profile_name,
        vpc_security_group_ids=[security_group_id],
        user_data=user_data,
        user_data_replace_on_change=True,  # Bootstrap is idempotent — safe to re-run
        root_block_device=aws.ec2.InstanceRootBlockDeviceArgs(
            volume_size=150,
            volume_type="gp3",
            encrypted=True,
            delete_on_termination=True,
        ),
        metadata_options=aws.ec2.InstanceMetadataOptionsArgs(
            http_tokens="required",
            http_put_response_hop_limit=1,
        ),
        tags={"Name": make_name("instance"), "Project": PROJECT_NAME},
    )

    eip = aws.ec2.Eip(
        make_name("eip"),
        instance=instance.id,
        tags={"Name": make_name("eip")},
    )

    return InstanceResources(instance=instance, eip=eip)
