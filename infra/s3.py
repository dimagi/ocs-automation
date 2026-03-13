# infra/s3.py
import pulumi_aws as aws
from infra.config import make_name, PROJECT_NAME, environment


def create_artifacts_bucket() -> aws.s3.BucketV2:
    """S3 bucket for session artifacts (logs, outputs)."""
    bucket = aws.s3.BucketV2(
        make_name("artifacts"),
        bucket=f"{PROJECT_NAME}-{environment}-artifacts",
        tags={"Name": make_name("artifacts"), "Project": PROJECT_NAME},
    )

    aws.s3.BucketVersioningV2(
        make_name("artifacts-versioning"),
        bucket=bucket.id,
        versioning_configuration=aws.s3.BucketVersioningV2VersioningConfigurationArgs(
            status="Enabled",
        ),
    )

    aws.s3.BucketLifecycleConfigurationV2(
        make_name("artifacts-lifecycle"),
        bucket=bucket.id,
        rules=[
            aws.s3.BucketLifecycleConfigurationV2RuleArgs(
                id="expire-old-versions",
                status="Enabled",
                noncurrent_version_expiration=aws.s3.BucketLifecycleConfigurationV2RuleNoncurrentVersionExpirationArgs(
                    noncurrent_days=30,
                ),
            )
        ],
    )

    aws.s3.BucketPublicAccessBlock(
        make_name("artifacts-pab"),
        bucket=bucket.id,
        block_public_acls=True,
        block_public_policy=True,
        ignore_public_acls=True,
        restrict_public_buckets=True,
    )

    aws.s3.BucketServerSideEncryptionConfigurationV2(
        make_name("artifacts-sse"),
        bucket=bucket.id,
        rules=[
            aws.s3.BucketServerSideEncryptionConfigurationV2RuleArgs(
                apply_server_side_encryption_by_default=aws.s3.BucketServerSideEncryptionConfigurationV2RuleApplyServerSideEncryptionByDefaultArgs(
                    sse_algorithm="aws:kms",
                ),
            )
        ],
    )

    return bucket
