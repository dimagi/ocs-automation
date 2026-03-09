#!/bin/bash
# scripts/deploy.sh
# Update OpenClaw config and skills on a running EC2 instance.
# Usage: ./scripts/deploy.sh <instance-id>
set -euo pipefail

INSTANCE_ID="${1:-}"
if [ -z "$INSTANCE_ID" ]; then
    echo "Usage: $0 <instance-id>"
    echo "Get instance ID: pulumi stack output instance_id"
    exit 1
fi

REGION="${AWS_REGION:-ap-southeast-2}"
BUCKET="ocs-automation-artifacts"

echo "Deploying to instance $INSTANCE_ID in region $REGION..."

# Upload openclaw config/skills and session container to S3
aws s3 sync openclaw/ "s3://$BUCKET/openclaw/" --region "$REGION"
aws s3 sync session/ "s3://$BUCKET/session/" --region "$REGION"
aws s3 sync scripts/ "s3://$BUCKET/scripts/" --region "$REGION"

echo "Synced files to s3://$BUCKET"

# Run update commands on the instance via SSM
COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --region "$REGION" \
    --parameters "commands=[
        \"aws s3 sync s3://$BUCKET/openclaw/ /data/openclaw/ --region $REGION\",
        \"aws s3 sync s3://$BUCKET/session/ /opt/ocs-automation/session/ --region $REGION\",
        \"chmod +x /data/openclaw/skills/ocs/session-manager.sh\",
        \"cd /opt/ocs-automation/openclaw && docker compose pull && docker compose up -d\",
        \"docker build -t ocs-session /opt/ocs-automation/session/ 2>&1 | tail -5\"
    ]" \
    --query "Command.CommandId" \
    --output text)

echo "SSM command dispatched: $COMMAND_ID"
echo "Check status: aws ssm get-command-invocation --command-id $COMMAND_ID --instance-id $INSTANCE_ID --region $REGION"
echo ""
echo "Or watch live: aws ssm list-command-invocations --command-id $COMMAND_ID --details --region $REGION"
