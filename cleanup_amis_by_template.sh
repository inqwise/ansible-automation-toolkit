#!/bin/bash

# Enable strict error handling
set -euo pipefail

# Variables without default values (since region is now mandatory)
PROFILE=""
REGION=""
DRY_RUN="false"
KEEP_HISTORY=1
TEMPLATE_NAME=""

# Function to show usage/help
usage() {
    echo "Usage: $0 --template <template_name> --region <region> [--profile <profile>] [--keep-history <keep_history>] [--dry-run]"
    echo
    echo "Options:"
    echo "  --template      Launch template name (mandatory)"
    echo "  --region        AWS region to use (mandatory)"
    echo "  --profile       AWS profile to use (optional)"
    echo "  --keep-history  Total number of AMIs to keep including the active AMI (default: 1)"
    echo "  --dry-run       Enable dry run mode (default: false)"
    exit 1
}

# Function to parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --template)
                TEMPLATE_NAME="$2"
                shift 2
                ;;
            --profile)
                PROFILE="$2"
                shift 2
                ;;
            --region)
                REGION="$2"
                shift 2
                ;;
            --keep-history)
                KEEP_HISTORY="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN="true"
                shift 1
                ;;
            --help)
                usage
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                ;;
        esac
    done

    if [[ -z "$TEMPLATE_NAME" ]]; then
        echo "Error: --template <template_name> is required" >&2
        usage
    fi

    if [[ -z "$REGION" ]]; then
        echo "Error: --region <region> is required" >&2
        usage
    fi
}

# Function to construct AWS CLI arguments
construct_aws_args() {
    local args=()
    if [[ -n "$PROFILE" ]]; then
        args+=(--profile "$PROFILE")
    fi
    args+=(--region "$REGION")
    echo "${args[@]}"
}

# Function to fetch the active AMI for the provided template
get_active_ami_for_template() {
    echo "Fetching active AMI for template: $TEMPLATE_NAME..." >&2
    aws ec2 describe-launch-template-versions \
        $(construct_aws_args) \
        --launch-template-name "$TEMPLATE_NAME" \
        --query 'LaunchTemplateVersions[?DefaultVersion==`true`].LaunchTemplateData.ImageId' \
        --output text
}

# Function to fetch AMI name based on the AMI ID
get_ami_name() {
    local ami_id="$1"
    aws ec2 describe-images $(construct_aws_args) \
        --image-ids "$ami_id" --query 'Images[0].Name' --output text
}

# Function to fetch the 'app' tag from the active AMI
get_app_tag() {
    local ami_id="$1"
    echo "Fetching 'app' tag for AMI: $ami_id" >&2
    app_tag=$(aws ec2 describe-images $(construct_aws_args) \
        --image-ids "$ami_id" \
        --query 'Images[0].Tags[?Key==`app`].Value | [0]' \
        --output text)

    if [[ -z "$app_tag" || "$app_tag" == "None" ]]; then
        echo "Error: 'app' tag is missing or empty for AMI: $ami_id" >&2
        exit 1
    fi

    echo "App tag value: $app_tag" >&2
    echo "$app_tag"
}

# Function to get the owner ID of an AMI
get_ami_owner() {
    local ami_id="$1"
    aws ec2 describe-images $(construct_aws_args) \
        --image-ids "$ami_id" \
        --query 'Images[0].OwnerId' \
        --output text
}

# Function to get the current AWS account ID
get_current_account_id() {
    aws sts get-caller-identity $(construct_aws_args) \
        --query 'Account' \
        --output text
}

# Function to get obsolete AMIs based on the active AMI
get_obsolete_amis() {
    local active_ami="$1"
    local app="$2"

    echo "Fetching details for active AMI: $active_ami" >&2

    # Get the creation date of the active AMI
    active_ami_data=$(aws ec2 describe-images $(construct_aws_args) \
        --image-ids "$active_ami" --query 'Images[0].{CreationDate:CreationDate}' --output json)

    active_ami_creation_date=$(echo "$active_ami_data" | jq -r '.CreationDate')

    echo "Active AMI Creation Date: $active_ami_creation_date" >&2

    # Fetch all AMIs that have the 'app' tag equal to the active app
    echo "Fetching AMIs with tag 'app' equal to: $app" >&2
    matching_amis=$(aws ec2 describe-images $(construct_aws_args) \
        --owners self \
        --filters "Name=tag:app,Values=$app" \
        --query 'Images[*].{ID:ImageId,Name:Name,CreationDate:CreationDate}' \
        --output json)

    echo "Total matching AMIs found: $(echo "$matching_amis" | jq length)" >&2

    # Sort AMIs by CreationDate in ascending order (oldest first)
    obsolete_amis=$(echo "$matching_amis" | jq --arg active_date "$active_ami_creation_date" '
    sort_by(.CreationDate) |
    .[] | select(.CreationDate < $active_date)' | jq -s '.')

    # Log details of the obsolete AMIs
    echo "Obsolete AMIs found: $(echo "$obsolete_amis" | jq length)" >&2
    echo "$obsolete_amis" | jq -r '.[] | "AMI Name: \(.Name), AMI ID: \(.ID), Creation Date: \(.CreationDate)"' >&2

    # Return the list of obsolete AMIs
    echo "$obsolete_amis"
}

# Function to delete obsolete AMIs and their snapshots
delete_obsolete_amis() {
    local obsolete_amis="$1"
    local total_matching=$(echo "$obsolete_amis" | jq length)
    local total_to_keep="$KEEP_HISTORY"

    # Ensure KEEP_HISTORY is at least 1
    if [[ "$total_to_keep" -lt 1 ]]; then
        echo "KEEP_HISTORY must be at least 1 to include the active AMI." >&2
        exit 1
    fi

    total_to_delete=$((total_matching - total_to_keep))

    if [ "$total_to_delete" -gt 0 ]; then
        echo "Preparing to delete $total_to_delete obsolete AMIs..." >&2
        # Sort obsolete AMIs by CreationDate ascending (oldest first)
        # and keep the most recent 'KEEP_HISTORY' AMIs
        AMIS_TO_DELETE=$(echo "$obsolete_amis" | jq --argjson keep "$KEEP_HISTORY" '
            sort_by(.CreationDate) |
            reverse |
            .[$keep:]')

        echo "$AMIS_TO_DELETE" | jq -r '.[] | "\(.Name) (\(.ID))"' | while read ami_info; do
            ami_id=$(echo "$ami_info" | awk -F'[()]' '{print $2}')
            ami_name=$(echo "$ami_info" | awk -F'[()]' '{print $1}')

            if [[ "$DRY_RUN" == "false" ]]; then
                echo "Preparing to delete AMI: $ami_name ($ami_id)" >&2

                # Fetch associated snapshots and store in variable
                snapshot_ids=$(aws ec2 describe-images $(construct_aws_args) \
                    --image-ids "$ami_id" --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' --output text)

                # Store snapshots in an array
                snapshot_array=()
                if [[ -n "$snapshot_ids" && "$snapshot_ids" != "None" ]]; then
                    echo "Snapshots associated with AMI: $ami_id:" >&2
                    for snapshot_id in $snapshot_ids; do
                        echo "Snapshot: $snapshot_id" >&2
                        snapshot_array+=("$snapshot_id")
                    done
                else
                    echo "No snapshots found for AMI: $ami_id" >&2
                fi

                # Deregister the AMI
                echo "Deregistering AMI: $ami_name ($ami_id)" >&2
                if aws ec2 deregister-image $(construct_aws_args) --image-id "$ami_id"; then
                    echo "Successfully deregistered AMI: $ami_name ($ami_id)" >&2

                    # Delete the associated snapshots after successful deregistration
                    if [[ ${#snapshot_array[@]} -gt 0 ]]; then
                        for snapshot_id in "${snapshot_array[@]}"; do
                            echo "Deleting snapshot: $snapshot_id associated with AMI: $ami_id" >&2
                            aws ec2 delete-snapshot $(construct_aws_args) --snapshot-id "$snapshot_id"
                        done
                    else
                        echo "No snapshots to delete for AMI: $ami_id" >&2
                    fi
                else
                    echo "Failed to deregister AMI: $ami_name ($ami_id). Skipping snapshot deletion." >&2
                fi
            else
                echo "DRY RUN: Would delete AMI: $ami_name ($ami_id)" >&2

                # Print snapshot IDs for dry run
                snapshot_ids=$(aws ec2 describe-images $(construct_aws_args) \
                    --image-ids "$ami_id" --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' --output text)

                if [[ -n "$snapshot_ids" && "$snapshot_ids" != "None" ]]; then
                    for snapshot_id in $snapshot_ids; do
                        echo "DRY RUN: Would delete snapshot: $snapshot_id associated with AMI: $ami_id" >&2
                    done
                else
                    echo "DRY RUN: No snapshots found for AMI: $ami_id" >&2
                fi
            fi
        done
    else
        echo "No obsolete AMIs to delete." >&2
    fi
}

# Call parse_args to process command-line arguments
parse_args "$@"

# Main
# echo "Profile: $PROFILE, Region: $REGION, DRY_RUN: $DRY_RUN, Keep History: $KEEP_HISTORY" >&2

# Get the active AMI for the provided template
active_ami=$(get_active_ami_for_template)
if [[ -n "$active_ami" && "$active_ami" != "None" ]]; then
    ami_name=$(get_ami_name "$active_ami")
    echo "Active AMI for template $TEMPLATE_NAME: $ami_name ($active_ami)" >&2

    # Get the owner ID of the active AMI
    ami_owner=$(get_ami_owner "$active_ami")
    echo "Active AMI Owner ID: $ami_owner" >&2

    # Get the current AWS account ID
    current_account_id=$(get_current_account_id)
    echo "Current AWS Account ID: $current_account_id" >&2

    # Check if the AMI owner is the current account
    if [[ "$ami_owner" != "$current_account_id" ]]; then
        echo "Info: Active AMI ($active_ami) is owned by another account ($ami_owner). Skipping operations." >&2
        exit 0
    fi

    # Get the 'app' tag from the active AMI
    app=$(get_app_tag "$active_ami")

    # Get obsolete AMIs based on the active AMI and 'app' tag
    obsolete_amis=$(get_obsolete_amis "$active_ami" "$app")

    # Print and delete the AMIs
    if [[ $(echo "$obsolete_amis" | jq length) -gt "$KEEP_HISTORY" ]]; then
        echo "$obsolete_amis" | jq -r '.[] | "\(.Name) (\(.ID))"' >&2
        delete_obsolete_amis "$obsolete_amis"
    else
        echo "No obsolete AMIs to delete." >&2
    fi
else
    echo "No active AMI found for template: $TEMPLATE_NAME" >&2
    exit 1
fi