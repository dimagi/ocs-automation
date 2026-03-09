# infra/ec2.py
import pathlib
from typing import TypedDict

import pulumi
import pulumi_aws as aws
from infra.config import make_name, instance_type, PROJECT_NAME


class InstanceResources(TypedDict):
    instance: aws.ec2.Instance
    eip: aws.ec2.Eip
    data_volume: aws.ebs.Volume


def create_instance(
    security_group_id: pulumi.Output,
    instance_profile_name: pulumi.Output,
    domain: str,
) -> InstanceResources:
    """
    EC2 instance for OpenClaw.
    - Ubuntu 24.04 LTS (ap-southeast-2)
    - 100GB gp3 root + 200GB gp3 data volume
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
        user_data_replace_on_change=False,  # Intentional: bootstrap runs once at first boot only
        root_block_device=aws.ec2.InstanceRootBlockDeviceArgs(
            volume_size=100,
            volume_type="gp3",
            delete_on_termination=True,
        ),
        tags={"Name": make_name("instance"), "Project": PROJECT_NAME},
    )

    data_volume = aws.ebs.Volume(
        make_name("data-volume"),
        availability_zone=instance.availability_zone,
        size=200,
        type="gp3",
        tags={"Name": make_name("data-volume")},
    )

    aws.ec2.VolumeAttachment(
        make_name("data-volume-attachment"),
        instance_id=instance.id,
        volume_id=data_volume.id,
        device_name="/dev/sdf",
    )

    eip = aws.ec2.Eip(
        make_name("eip"),
        instance=instance.id,
        tags={"Name": make_name("eip")},
    )

    return InstanceResources(instance=instance, eip=eip, data_volume=data_volume)
