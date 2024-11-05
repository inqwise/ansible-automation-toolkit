#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Function to display usage information
usage() {
    echo "Usage: $0 --ami ami-id --region region [--profile profile] [--dry-run]"
    echo ""
    echo "Options:"
    echo "  --ami       The AMI ID to deregister (required)"
    echo "  --region    AWS region (required)"
    echo "  --profile   AWS CLI profile to use (optional)"
    echo "  --dry-run   Show actions without executing them"
    echo "  -h, --help  Show this help message and exit"
}

# Initialize variables
AMI_ID=""
REGION=""
PROFILE=""
DRY_RUN=false

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --ami)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                AMI_ID="$2"
                shift 2
            else
                echo "Error: --ami requires a non-empty argument."
                usage
                exit 1
            fi
            ;;
        --region)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                REGION="$2"
                shift 2
            else
                echo "Error: --region requires a non-empty argument."
                usage
                exit 1
            fi
            ;;
        --profile)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                PROFILE="$2"
                shift 2
            else
                echo "Error: --profile requires a non-empty argument."
                usage
                exit 1
            fi
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown parameter passed: $1"
            usage
            exit 1
            ;;
    esac
done

# Check if required parameters are provided
if [[ -z "$AMI_ID" ]]; then
    echo "Error: --ami parameter is required."
    usage
    exit 1
fi

if [[ -z "$REGION" ]]; then
    echo "Error: --region parameter is required."
    usage
    exit 1
fi

# Prepare AWS CLI options
AWS_OPTIONS="--region $REGION"
if [[ -n "$PROFILE" ]]; then
    AWS_OPTIONS="$AWS_OPTIONS --profile $PROFILE"
fi

# Temporary file to store snapshot IDs
SNAPSHOT_LIST=$(mktemp)

# Cleanup function to remove temporary file on exit
cleanup() {
    rm -f "$SNAPSHOT_LIST"
}
trap cleanup EXIT

echo "Retrieving snapshot IDs associated with AMI $AMI_ID..."
SNAPSHOT_IDS=$(aws ec2 describe-images --image-ids "$AMI_ID" \
    --query 'Images[].BlockDeviceMappings[].Ebs.SnapshotId' \
    --output text $AWS_OPTIONS)

if [[ -z "$SNAPSHOT_IDS" ]]; then
    echo "No snapshots found for AMI $AMI_ID."
else
    echo "Found snapshots: $SNAPSHOT_IDS"
    # Save snapshot IDs to the temporary file
    echo "$SNAPSHOT_IDS" > "$SNAPSHOT_LIST"
fi

# Function to perform actions or dry run
execute() {
    if $DRY_RUN; then
        echo "Dry run: $*"
    else
        "$@"
    fi
}

if $DRY_RUN; then
    echo "Dry run: Deregistering AMI $AMI_ID in region $REGION."
else
    echo "Deregistering AMI: $AMI_ID in region: $REGION"
    execute aws ec2 deregister-image --image-id "$AMI_ID" $AWS_OPTIONS
    echo "AMI $AMI_ID deregistered successfully."
fi

if [[ -s "$SNAPSHOT_LIST" ]]; then
    while read -r SNAPSHOT_ID; do
        if [[ -n "$SNAPSHOT_ID" ]]; then
            if $DRY_RUN; then
                echo "Dry run: Deleting snapshot $SNAPSHOT_ID"
            else
                echo "Deleting snapshot: $SNAPSHOT_ID"
                execute aws ec2 delete-snapshot --snapshot-id "$SNAPSHOT_ID" $AWS_OPTIONS
                echo "Snapshot $SNAPSHOT_ID deleted."
            fi
        fi
    done < "$SNAPSHOT_LIST"

    echo "All associated snapshots deleted successfully."
fi

echo "Script completed successfully."
exit 0