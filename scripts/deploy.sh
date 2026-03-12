#!/bin/bash
# scripts/deploy.sh
# Update OpenClaw config, skills, Caddy, and session image on a running EC2 instance.
# Usage: ./scripts/deploy.sh [instance-id]
#   If instance-id is omitted, auto-resolves from Pulumi stack output.
set -euo pipefail

INSTANCE_ID="${1:-}"
if [ -z "$INSTANCE_ID" ]; then
    INSTANCE_ID=$(op run --env-file=.pulumi.env -- pulumi stack output instance_id 2>/dev/null) || true
    if [ -z "$INSTANCE_ID" ]; then
        echo "Usage: $0 <instance-id>"
        echo "Get instance ID: pulumi stack output instance_id"
        exit 1
    fi
fi

REGION="${AWS_REGION:-us-east-1}"
BUCKET="ocs-automation-prod-artifacts"

# Get domain from Pulumi config (authoritative source)
DOMAIN=$(op run --env-file=.pulumi.env -- pulumi config get domain 2>/dev/null) || true
if [ -z "$DOMAIN" ]; then
    echo "WARNING: Could not get domain from Pulumi config. Caddyfile will not be updated." >&2
fi

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

# Upload openclaw config/skills, session container, and scripts to S3
step "Syncing openclaw/ to S3..."
aws s3 sync openclaw/ "s3://$BUCKET/deploy/openclaw/" --region "$REGION" --quiet
step "Syncing session/ to S3..."
aws s3 sync session/ "s3://$BUCKET/deploy/session/" --region "$REGION" --quiet
step "Syncing scripts/ to S3..."
aws s3 sync scripts/ "s3://$BUCKET/deploy/scripts/" --region "$REGION" --quiet
success "S3 sync complete"

# Run update commands on the instance via SSM
info "Sending SSM commands to instance..."
COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --region "$REGION" \
    --timeout-seconds 300 \
    --parameters "commands=[
        \"set -euo pipefail\",
        \"echo '>>> Syncing from S3...'\",
        \"aws s3 sync s3://$BUCKET/deploy/ /opt/ocs-automation/ --delete --region $REGION\",
        \"echo '>>> Updating skills...'\",
        \"cp -r /opt/ocs-automation/openclaw/skills/* /opt/openclaw/skills/\",
        \"echo '>>> Updating Caddyfile...'\",
        \"cp /opt/ocs-automation/openclaw/Caddyfile /etc/caddy/Caddyfile\",
        \"sed -i 's/__DOMAIN__/$DOMAIN/g' /etc/caddy/Caddyfile\",
        \"systemctl reload caddy || true\",
        \"echo '>>> Rebuilding session image...'\",
        \"docker build -t ocs-session /opt/ocs-automation/session/ 2>&1 | tail -5\",
        \"echo '>>> Restarting OpenClaw gateway...'\",
        \"systemctl restart openclaw-gateway\",
        \"echo '>>> Deploy complete on instance'\"
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
