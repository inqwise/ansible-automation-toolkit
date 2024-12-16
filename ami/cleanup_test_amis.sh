#!/usr/bin/env bash

set -euo pipefail

PROFILE=""
REGION=""
DRY_RUN="false"
TOOLKIT_VERSION=${TOOLKIT_VERSION:-default}

function usage() {
    cat <<EOF
Usage: $0 [--profile <aws_profile>] [--region <aws_region>] [--dry-run] [--help]

Options:
  --profile <aws_profile> : Use specified AWS CLI profile.
  --region  <aws_region>  : Specify the AWS region.
  --dry-run               : Show which AMIs would be deregistered without performing it.
  --help                  : Show this help message.

Description:
  This script searches for AMIs containing '-test' in their name that were created by you
  and deregisters them using a remote deregister_ami.sh script (downloaded if not present).

  In dry-run mode, it will only list the AMIs and not perform deregistration.

Environment Variables:
  TOOLKIT_VERSION: Defaults to 'default' if not set. Used to determine which version 
                   of deregister_ami.sh to download.

Examples:
  $0 --profile my-profile --region eu-central-1
  $0 --profile my-profile --region eu-central-1 --dry-run
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            shift
            if [[ $# -lt 1 ]]; then
                echo "Error: --profile requires an argument."
                usage
                exit 1
            fi
            PROFILE="$1"
            shift
            ;;
        --region)
            shift
            if [[ $# -lt 1 ]]; then
                echo "Error: --region requires an argument."
                usage
                exit 1
            fi
            REGION="$1"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

DEREGISTER_SCRIPT_URL="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/${TOOLKIT_VERSION}/ami/deregister_ami.sh"
DEREGISTER_SCRIPT="./deregister_ami.sh"

# Download deregister_ami.sh if it doesn't exist locally
if [[ ! -f "$DEREGISTER_SCRIPT" ]]; then
  echo "Local version of deregister_ami.sh not found. Downloading from $DEREGISTER_SCRIPT_URL..."
  curl -sSL -o "$DEREGISTER_SCRIPT" "$DEREGISTER_SCRIPT_URL"
  chmod +x "$DEREGISTER_SCRIPT"
fi

# Build the AWS CLI command to describe images (without dry-run) using owner's AMIs
BASE_CMD=(aws ec2 describe-images --owners self --filters "Name=name,Values=*-test*")
if [[ -n "$PROFILE" ]]; then
    BASE_CMD+=(--profile "$PROFILE")
fi
if [[ -n "$REGION" ]]; then
    BASE_CMD+=(--region "$REGION")
fi

echo "Fetching AMIs (without dry-run) to list found images..."
OUTPUT="$("${BASE_CMD[@]}" 2>/dev/null || true)"

# Extract AMI IDs and Names into a JSON array of objects: [{ImageId, Name}, ...]
AMI_LIST=$(echo "$OUTPUT" | jq '[.Images[] | {ImageId: .ImageId, Name: .Name}]' 2>/dev/null || echo "[]")

if [[ $(echo "$AMI_LIST" | jq 'length') -eq 0 ]]; then
    echo "No AMIs found containing '-test' that you own."
else
    echo "Found AMIs:"
    echo "$AMI_LIST" | jq '.'
fi

# If dry-run, do not proceed with actual deregistration
if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry run enabled. Would have deregistered above AMIs, but not actually performing it."
    exit 0
fi

# Proceed with deregistration if not dry-run
if [[ $(echo "$AMI_LIST" | jq 'length') -eq 0 ]]; then
    # No AMIs to deregister
    exit 0
fi

# Prepare profile arg for deregister_ami.sh
if [[ -n "$PROFILE" ]]; then
    PROFILE_ARG="--profile $PROFILE"
else
    PROFILE_ARG=""
fi

# Deregister each found AMI
echo "$AMI_LIST" | jq -c '.[]' | while read -r ami; do
    ami_id=$(echo "$ami" | jq -r '.ImageId')
    ami_name=$(echo "$ami" | jq -r '.Name')

    echo "Deregistering AMI: $ami_id ($ami_name)"
    set +e
    bash "$DEREGISTER_SCRIPT" --ami "$ami_id" --region "$REGION" $PROFILE_ARG
    if [[ $? -ne 0 ]]; then
        echo "Error deregistering AMI: ID=$ami_id, Name=$ami_name"
    fi
    set -e
done