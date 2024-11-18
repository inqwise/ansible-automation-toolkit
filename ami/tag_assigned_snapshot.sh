#!/bin/bash

set -eu

# Function to display usage
usage() {
    echo "Usage: $0 --region <region> [--profile <profile>]"
    echo "Options:"
    echo "  --region       AWS region (required)"
    echo "  --profile      AWS CLI profile to use (optional)"
    exit 1
}

# Initialize variables
REGION=""
PROFILE=""
TAG_NAMES=("Name" "app" "version" "timestamp" "amm:source_region" "amm:source_account" "amm:source_ami")

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --region)
            REGION="$2"
            shift 2
            ;;
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        *)
            echo "Unknown parameter: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "$REGION" ]]; then
    echo "Error: --region is required."
    usage
fi

echo "Fetching AMIs and their snapshots in region $REGION..."

# Fetch AMIs and their associated snapshots, skipping AMIs with amm:SkipTagging=true or amm:snapshot_tagging_status tag
amis=$(aws ec2 describe-images \
    --region "$REGION" \
    ${PROFILE:+--profile "$PROFILE"} \
    --owners self \
    --query "Images[?!(Tags[?Key=='amm:SkipTagging' && Value=='true'] || Tags[?Key=='amm:snapshot_tagging_status'])].{ImageId:ImageId,Tags:Tags,Snapshots:BlockDeviceMappings[*].Ebs.SnapshotId}" \
    --output json)

if [[ "$amis" == "[]" ]]; then
    echo "No eligible AMIs found."
    exit 0
fi

echo "Processing AMIs and their snapshots..."

# Process each AMI and its associated snapshots
echo "$amis" | jq -c '.[]' | while IFS= read -r ami; do
    ami_id=$(echo "$ami" | jq -r '.ImageId')
    all_tags=$(echo "$ami" | jq -c '.Tags // []')
    snapshots=$(echo "$ami" | jq -r '.Snapshots[]')

    # Filter tags to copy only those in TAG_NAMES
    filtered_tags=$(echo "$all_tags" | jq --argjson tag_names "$(printf '%s\n' "${TAG_NAMES[@]}" | jq -R . | jq -s .)" '
        map(select(.Key as $k | $tag_names | index($k) != null))')

    if [[ "$filtered_tags" == "[]" ]]; then
        echo "AMI $ami_id has no relevant tags to copy. Skipping snapshots."
        aws ec2 create-tags \
            --region "$REGION" \
            ${PROFILE:+--profile "$PROFILE"} \
            --resources "$ami_id" \
            --tags "Key=amm:snapshot_tagging_status,Value=skipped"
        continue
    fi

    echo "AMI: $ami_id"
    echo "Tags to copy: $filtered_tags"
    echo "Snapshots: $snapshots"

    snapshot_tagged=false

    # Tag each snapshot with the filtered tags
    for snapshot in $snapshots; do
        if [[ "$snapshot" == "null" || -z "$snapshot" ]]; then
            continue
        fi

        # Check if snapshot already has tags
        existing_tags=$(aws ec2 describe-tags \
            --region "$REGION" \
            ${PROFILE:+--profile "$PROFILE"} \
            --filters "Name=resource-id,Values=$snapshot" \
            --query "Tags" \
            --output json)

        if [[ "$existing_tags" != "[]" ]]; then
            echo "Snapshot $snapshot already has tags. Skipping."
            continue
        fi

        echo "Tagging snapshot $snapshot with tags from AMI $ami_id..."
        aws ec2 create-tags \
            --region "$REGION" \
            ${PROFILE:+--profile "$PROFILE"} \
            --resources "$snapshot" \
            --tags "$filtered_tags"
        echo "Snapshot $snapshot tagged successfully."
        snapshot_tagged=true
    done

    # Add tagging status to the AMI
    if $snapshot_tagged; then
        echo "AMI $ami_id: snapshots tagged. Adding status 'changed'."
        aws ec2 create-tags \
            --region "$REGION" \
            ${PROFILE:+--profile "$PROFILE"} \
            --resources "$ami_id" \
            --tags "Key=amm:snapshot_tagging_status,Value=changed"
    else
        echo "AMI $ami_id: all snapshots skipped. Adding status 'skipped'."
        aws ec2 create-tags \
            --region "$REGION" \
            ${PROFILE:+--profile "$PROFILE"} \
            --resources "$ami_id" \
            --tags "Key=amm:snapshot_tagging_status,Value=skipped"
    fi
done

echo "All AMIs and snapshots processed."