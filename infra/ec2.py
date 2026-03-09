# infra/ec2.py
import pulumi
import pulumi_aws as aws
from infra.config import make_name, instance_type


def create_instance(
    security_group_id: pulumi.Output,
    instance_profile_name: pulumi.Output,
) -> dict:
    """
    EC2 instance for OpenClaw.
    - Ubuntu 24.04 LTS (ap-southeast-2)
    - 100GB gp3 root + 200GB gp3 data volume
    - SSM-managed, no SSH key required
    """

    # Ubuntu 24.04 LTS AMI — look up dynamically from Canonical
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

    with open("scripts/bootstrap.sh") as f:
        user_data = f.read()

    instance = aws.ec2.Instance(
        make_name("instance"),
        ami=ami.id,
        instance_type=instance_type,
        iam_instance_profile=instance_profile_name,
        vpc_security_group_ids=[security_group_id],
        user_data=user_data,
        user_data_replace_on_change=False,
        root_block_device=aws.ec2.InstanceRootBlockDeviceArgs(
            volume_size=100,
            volume_type="gp3",
            delete_on_termination=True,
        ),
        tags={"Name": make_name("instance"), "Project": "ocs-automation"},
    )

    # Separate data EBS volume (persists if instance replaced)
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

    # Elastic IP for stable address
    eip = aws.ec2.Eip(
        make_name("eip"),
        instance=instance.id,
        tags={"Name": make_name("eip")},
    )

    return {"instance": instance, "eip": eip, "data_volume": data_volume}
