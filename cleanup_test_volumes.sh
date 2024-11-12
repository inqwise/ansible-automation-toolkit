#!/bin/bash

set -eu

# Default values for arguments
PROFILE=""
DRY_RUN=false
NAME_PATTERN="*-test*"

# Usage function to display help
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --profile PROFILE         AWS CLI profile to use (optional)"
    echo "  --region REGION           AWS region to use (required)"
    echo "  --dry-run                 Enable dry-run mode (default: disabled)"
    echo "  -h, --help                Display this help message"
    exit 1
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --profile)
            if [[ -n "${2:-}" && ! "$2" =~ ^-- ]]; then
                PROFILE="$2"
                shift
            else
                echo "Error: --profile requires a non-empty option argument."
                usage
            fi
            ;;
        --region)
            if [[ -n "${2:-}" && ! "$2" =~ ^-- ]]; then
                REGION="$2"
                shift
            else
                echo "Error: --region requires a non-empty option argument."
                usage
            fi
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown parameter passed: $1"
            usage
            ;;
    esac
    shift
done

# Check if region is provided
if [[ -z "${REGION:-}" ]]; then
    echo "Error: --region is mandatory."
    usage
fi

# Construct AWS CLI profile argument if PROFILE is set
AWS_PROFILE_ARG=()
if [[ -n "$PROFILE" ]]; then
    AWS_PROFILE_ARG=(--profile "$PROFILE")
fi

# Function to delete EBS volumes
cleanup_ebs_volumes() {
    echo "Searching for 'Available' EBS volumes with name pattern '$NAME_PATTERN' in region '$REGION'..."

    # Get the volume IDs of volumes with name matching the pattern and state 'Available'
    volume_ids=$(aws ec2 describe-volumes \
        "${AWS_PROFILE_ARG[@]}" \
        --region "$REGION" \
        --filters "Name=tag:Name,Values=$NAME_PATTERN" "Name=status,Values=available" \
        --query "Volumes[*].VolumeId" \
        --output text)

    if [[ -z "$volume_ids" ]]; then
        echo "No available volumes found matching the name pattern."
        exit 0
    fi

    echo "Found volumes: $volume_ids"

    # Loop through each volume and delete it
    for volume_id in $volume_ids; do
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "Dry run: Would delete volume $volume_id"
        else
            echo "Deleting volume $volume_id..."
            aws ec2 delete-volume \
                "${AWS_PROFILE_ARG[@]}" \
                --region "$REGION" \
                --volume-id "$volume_id"
            if [[ $? -eq 0 ]]; then
                echo "Volume $volume_id deleted successfully."
            else
                echo "Failed to delete volume $volume_id."
            fi
        fi
    done
}

# Check if running in dry run mode
if [[ "$DRY_RUN" == "true" ]]; then
    echo "Running in dry run mode. No actual deletions will occur."
fi

# Call the function to clean up volumes
cleanup_ebs_volumes