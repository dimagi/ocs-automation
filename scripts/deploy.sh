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

REGION="${AWS_REGION:-us-east-1}"
BUCKET="ocs-automation-prod-artifacts"

# Colors
BOLD="\033[1m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
DIM="\033[2m"
RESET="\033[0m"
PREFIX="${BOLD}${CYAN}[deploy]${RESET}"

info()    { echo -e "${PREFIX} $*"; }
success() { echo -e "${PREFIX} ${GREEN}$*${RESET}"; }
step()    { echo -e "${PREFIX} ${DIM}$*${RESET}"; }
fail()    { echo -e "${PREFIX} ${RED}$*${RESET}" >&2; exit 1; }

info "Deploying to ${BOLD}${INSTANCE_ID}${RESET} in ${BOLD}${REGION}${RESET}"

# Upload openclaw config/skills and session container to S3
step "Syncing openclaw/ to S3..."
aws s3 sync openclaw/ "s3://$BUCKET/openclaw/" --region "$REGION" --quiet
step "Syncing session/ to S3..."
aws s3 sync session/ "s3://$BUCKET/session/" --region "$REGION" --quiet
step "Syncing scripts/ to S3..."
aws s3 sync scripts/ "s3://$BUCKET/scripts/" --region "$REGION" --quiet
success "S3 sync complete"

# Run update commands on the instance via SSM
info "Sending SSM commands to instance..."
COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --region "$REGION" \
    --parameters "commands=[
        \"aws s3 sync s3://$BUCKET/openclaw/ /data/openclaw/ --region $REGION\",
        \"aws s3 sync s3://$BUCKET/session/ /opt/ocs-automation/session/ --region $REGION\",
        \"chmod +x /data/openclaw/skills/ocs/session-manager.sh\",
        \"docker build -t ocs-session /opt/ocs-automation/session/ 2>&1 | tail -5\",
        \"cd /data/openclaw && docker compose build && docker compose up -d\"
    ]" \
    --query "Command.CommandId" \
    --output text)

step "SSM command: ${COMMAND_ID}"

# Poll for completion
POLL_INTERVAL=3
MAX_POLLS=120  # 6 minutes max
SPINNER=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
spin_idx=0
elapsed=0

for ((i=0; i<MAX_POLLS; i++)); do
    sleep $POLL_INTERVAL
    elapsed=$((elapsed + POLL_INTERVAL))

    RESULT=$(aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --region "$REGION" \
        --output json 2>/dev/null) || continue

    STATUS=$(echo "$RESULT" | jq -r '.Status')

    case "$STATUS" in
        InProgress|Pending|Delayed)
            spin=${SPINNER[$((spin_idx % ${#SPINNER[@]}))]}
            spin_idx=$((spin_idx + 1))
            printf "\r${PREFIX} ${DIM}%s Waiting for SSM command... (%ds)${RESET}  " "$spin" "$elapsed"
            ;;
        Success)
            printf "\r"
            success "SSM command completed (${elapsed}s)"
            echo ""
            STDOUT=$(echo "$RESULT" | jq -r '.StandardOutputContent // ""')
            STDERR=$(echo "$RESULT" | jq -r '.StandardErrorContent // ""')
            if [ -n "$STDOUT" ]; then
                echo -e "${DIM}--- stdout ---${RESET}"
                echo "$STDOUT"
            fi
            if [ -n "$STDERR" ]; then
                echo -e "${YELLOW}--- stderr ---${RESET}"
                echo "$STDERR"
            fi
            echo ""
            success "Deploy complete"
            exit 0
            ;;
        Failed|Cancelled|TimedOut)
            printf "\r"
            echo ""
            STDOUT=$(echo "$RESULT" | jq -r '.StandardOutputContent // ""')
            STDERR=$(echo "$RESULT" | jq -r '.StandardErrorContent // ""')
            if [ -n "$STDOUT" ]; then
                echo -e "${DIM}--- stdout ---${RESET}"
                echo "$STDOUT"
            fi
            if [ -n "$STDERR" ]; then
                echo -e "${RED}--- stderr ---${RESET}"
                echo "$STDERR"
            fi
            fail "SSM command ${STATUS} after ${elapsed}s"
            ;;
    esac
done

printf "\r"
fail "Timed out after $((MAX_POLLS * POLL_INTERVAL))s waiting for SSM command"
