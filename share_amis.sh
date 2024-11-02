#!/bin/bash

# Exit immediately if a pipeline returns a non-zero status
set -o pipefail

# Default values (if any)
AWS_PROFILE=""
REGION=""
TARGET_ACCOUNT_ID=""
REQUIRED_TAGS=("playbook_name" "version" "app")

# Function to display help message
usage() {
    echo "Usage: $0 --region REGION --target-account-id ACCOUNT_ID [--profile PROFILE]"
    echo ""
    echo "Options:"
    echo "  --region REGION                AWS region (e.g., us-west-2)"
    echo "  --target-account-id ACCOUNT_ID Target AWS account ID to share AMIs with"
    echo "  --profile PROFILE              AWS CLI profile to use (optional)"
    echo "  --help                         Display this help message"
    exit 1
}

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --region)
            REGION="$2"
            shift 2
            ;;
        --target-account-id)
            TARGET_ACCOUNT_ID="$2"
            shift 2
            ;;
        --profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            echo "Unknown parameter passed: $1"
            usage
            ;;
    esac
done

# Validation of mandatory variables
if [[ -z "$REGION" ]]; then
    echo "Error: --region is required."
    usage
fi

if [[ -z "$TARGET_ACCOUNT_ID" ]]; then
    echo "Error: --target-account-id is required."
    usage
fi

# Function to get all AMIs owned by self with required tags
get_owned_amis() {
    echo "Retrieving all AMIs owned by self in region $REGION with required tags..."

    # Build the filters for required tags
    filters=()
    for tag_key in "${REQUIRED_TAGS[@]}"; do
        filters+=(--filters "Name=tag-key,Values=$tag_key")
    done

    if [[ -n "$AWS_PROFILE" ]]; then
        AMI_IDS=$(aws ec2 describe-images \
            --owners self \
            "${filters[@]}" \
            --region "$REGION" \
            --profile "$AWS_PROFILE" \
            --query 'Images[*].ImageId' \
            --output text)
    else
        AMI_IDS=$(aws ec2 describe-images \
            --owners self \
            "${filters[@]}" \
            --region "$REGION" \
            --query 'Images[*].ImageId' \
            --output text)
    fi
}

# Function to check if AMI is shared with the target account
is_ami_shared() {
    local ami_id=$1
    if [[ -n "$AWS_PROFILE" ]]; then
        shared_accounts=$(aws ec2 describe-image-attribute \
            --image-id "$ami_id" \
            --attribute launchPermission \
            --region "$REGION" \
            --profile "$AWS_PROFILE" \
            --query 'LaunchPermissions[*].UserId' \
            --output text)
    else
        shared_accounts=$(aws ec2 describe-image-attribute \
            --image-id "$ami_id" \
            --attribute launchPermission \
            --region "$REGION" \
            --query 'LaunchPermissions[*].UserId' \
            --output text)
    fi

    for account in $shared_accounts; do
        if [ "$account" == "$TARGET_ACCOUNT_ID" ]; then
            return 0  # AMI is already shared
        fi
    done
    return 1  # AMI is not shared
}

# Function to share AMI with target account
share_ami() {
    local ami_id=$1
    echo "Sharing AMI $ami_id with account $TARGET_ACCOUNT_ID..."
    if [[ -n "$AWS_PROFILE" ]]; then
        output=$(aws ec2 modify-image-attribute \
            --image-id "$ami_id" \
            --launch-permission "Add=[{UserId=$TARGET_ACCOUNT_ID}]" \
            --region "$REGION" \
            --profile "$AWS_PROFILE" 2>&1)
    else
        output=$(aws ec2 modify-image-attribute \
            --image-id "$ami_id" \
            --launch-permission "Add=[{UserId=$TARGET_ACCOUNT_ID}]" \
            --region "$REGION" 2>&1)
    fi

    if [ $? -ne 0 ]; then
        echo "Error sharing AMI $ami_id: $output"
        echo "Skipping to next AMI."
        return 1
    fi

    # Share associated snapshots
    share_snapshots "$ami_id"

    # Add tag to AMI indicating successful sharing
    add_ami_tag "$ami_id"
}

# Function to share snapshots associated with an AMI
share_snapshots() {
    local ami_id=$1
    echo "Sharing snapshots associated with AMI $ami_id..."
    if [[ -n "$AWS_PROFILE" ]]; then
        SNAPSHOT_IDS=$(aws ec2 describe-images \
            --image-ids "$ami_id" \
            --region "$REGION" \
            --profile "$AWS_PROFILE" \
            --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' \
            --output text)
    else
        SNAPSHOT_IDS=$(aws ec2 describe-images \
            --image-ids "$ami_id" \
            --region "$REGION" \
            --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' \
            --output text)
    fi

    for snapshot_id in $SNAPSHOT_IDS; do
        echo "Sharing Snapshot $snapshot_id with account $TARGET_ACCOUNT_ID..."
        if [[ -n "$AWS_PROFILE" ]]; then
            output=$(aws ec2 modify-snapshot-attribute \
                --snapshot-id "$snapshot_id" \
                --attribute createVolumePermission \
                --operation-type add \
                --user-ids "$TARGET_ACCOUNT_ID" \
                --region "$REGION" \
                --profile "$AWS_PROFILE" 2>&1)
        else
            output=$(aws ec2 modify-snapshot-attribute \
                --snapshot-id "$snapshot_id" \
                --attribute createVolumePermission \
                --operation-type add \
                --user-ids "$TARGET_ACCOUNT_ID" \
                --region "$REGION" 2>&1)
        fi

        if [ $? -ne 0 ]; then
            echo "Error sharing Snapshot $snapshot_id: $output"
            echo "Skipping this snapshot."
            # Continue to next snapshot
            continue
        fi
    done
}

# Function to add a tag to the AMI indicating it has been shared
add_ami_tag() {
    local ami_id=$1
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local tag_key="SharedToAccount$TARGET_ACCOUNT_ID"
    local tag_value="$timestamp"
    echo "Adding tag to AMI $ami_id: $tag_key=$tag_value"
    if [[ -n "$AWS_PROFILE" ]]; then
        aws ec2 create-tags \
            --resources "$ami_id" \
            --tags Key="$tag_key",Value="$tag_value" \
            --region "$REGION" \
            --profile "$AWS_PROFILE"
    else
        aws ec2 create-tags \
            --resources "$ami_id" \
            --tags Key="$tag_key",Value="$tag_value" \
            --region "$REGION"
    fi
}

# Main script execution
get_owned_amis

if [ -z "$AMI_IDS" ]; then
    echo "No AMIs found in region $REGION with required tags for the specified profile."
    exit 0
fi

echo "Found AMIs with required tags: $AMI_IDS"

for ami_id in $AMI_IDS; do
    echo "Processing AMI $ami_id..."
    if is_ami_shared "$ami_id"; then
        echo "AMI $ami_id is already shared with account $TARGET_ACCOUNT_ID. Skipping..."
    else
        echo "AMI $ami_id is not shared with account $TARGET_ACCOUNT_ID."
        share_ami "$ami_id" || {
            echo "Failed to share AMI $ami_id. Continuing to next AMI."
            continue
        }
    fi
done

echo "Script execution completed."