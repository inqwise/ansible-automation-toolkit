#!/bin/bash

# Enable strict error handling
set -euo pipefail

# Variables with default values
PROFILE="default"
REGION="us-east-1"
DRY_RUN="false"
KEEP_HISTORY=1
TEMPLATE_NAME=""

# Function to show usage/help
usage() {
    echo "Usage: $0 --template <template_name> --profile <profile> --region <region> --keep-history <keep_history> --dry-run"
    echo
    echo "Options:"
    echo "  --template      Launch template name (mandatory)"
    echo "  --profile       AWS profile to use (default: default)"
    echo "  --region        AWS region to use (default: us-east-1)"
    echo "  --keep-history  Number of obsolete AMIs to keep (default: 1)"
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
                echo "Unknown option: $1"
                usage
                ;;
        esac
    done

    if [[ -z "$TEMPLATE_NAME" ]]; then
        echo "Error: --template <template_name> is required" >&2
        usage
    fi
}

# Call parse_args to process command-line arguments
parse_args "$@"

# Function to fetch the active AMI for the provided template
get_active_ami_for_template() {
    echo "Fetching active AMI for template: $TEMPLATE_NAME..." >&2
    aws ec2 describe-launch-template-versions \
        --profile "$PROFILE" \
        --region "$REGION" \
        --launch-template-name "$TEMPLATE_NAME" \
        --query 'LaunchTemplateVersions[?DefaultVersion==`true`].LaunchTemplateData.ImageId' \
        --output text
}

# Function to fetch AMI name based on the AMI ID
get_ami_name() {
    local ami_id="$1"
    aws ec2 describe-images --profile "$PROFILE" --region "$REGION" \
        --image-ids "$ami_id" --query 'Images[0].Name' --output text
}

# Function to get obsolete AMIs based on the active AMI
get_obsolete_amis() {
    local active_ami="$1"
    
    echo "Fetching details for active AMI: $active_ami" >&2
    
    # Get the creation date and name of the active AMI
    active_ami_data=$(aws ec2 describe-images --profile "$PROFILE" --region "$REGION" \
        --image-ids "$active_ami" --query 'Images[0].{Name:Name,CreationDate:CreationDate}' --output json)
    
    active_ami_name=$(echo "$active_ami_data" | jq -r '.Name')
    active_ami_creation_date=$(echo "$active_ami_data" | jq -r '.CreationDate')
    
    echo "Active AMI Name: $active_ami_name" >&2
    echo "Active AMI Creation Date: $active_ami_creation_date" >&2
    
    # Extract the prefix from the active AMI name (assuming prefix before first dash)
    ami_prefix=$(echo "$active_ami_name" | cut -d'-' -f1)
    
    echo "Using AMI prefix: $ami_prefix*" >&2

    # Fetch all AMIs that start with the same prefix
    echo "Fetching AMIs with the prefix: $ami_prefix*" >&2
    matching_amis=$(aws ec2 describe-images --profile "$PROFILE" --region "$REGION" \
        --owners self --filters "Name=name,Values=${ami_prefix}*" \
        --query 'Images[*].{ID:ImageId,Name:Name,CreationDate:CreationDate}' --output json)
    
    echo "Total matching AMIs found: $(echo "$matching_amis" | jq length)" >&2

    # Filter out active AMI and AMIs newer than the active AMI
    obsolete_amis=$(echo "$matching_amis" | jq --arg active_ami "$active_ami" --arg active_date "$active_ami_creation_date" '
    .[] | select(.ID != $active_ami and .CreationDate < $active_date)' | jq -s 'sort_by(.CreationDate)')

    # Log details of the obsolete AMIs
    echo "Obsolete AMIs found: $(echo "$obsolete_amis" | jq length)" >&2
    echo "$obsolete_amis" | jq -r '.[] | "AMI Name: \(.Name), AMI ID: \(.ID), Creation Date: \(.CreationDate)"' >&2

    # Return the list of obsolete AMIs
    echo "$obsolete_amis"
}

# Function to delete obsolete AMIs and print in the format ami_name (ami_id)
delete_obsolete_amis() {
    local obsolete_amis="$1"
    total_to_delete=$(($(echo "$obsolete_amis" | jq length) - $KEEP_HISTORY))
    
    if [ "$total_to_delete" -gt 0 ]; then
        echo "Preparing to delete $total_to_delete obsolete AMIs..." >&2
        echo "$obsolete_amis" | jq -r --argjson keep "$total_to_delete" '.[0:$keep] | .[] | "\(.Name) (\(.ID))"' | while read ami_info; do
            ami_id=$(echo "$ami_info" | awk -F'[()]' '{print $2}')
            ami_name=$(echo "$ami_info" | awk -F'[()]' '{print $1}')
            
            if [[ "$DRY_RUN" == "false" ]]; then
                echo "Deleting AMI: $ami_name ($ami_id)" >&2
                aws ec2 deregister-image --profile "$PROFILE" --region "$REGION" --image-id "$ami_id"
            else
                echo "DRY RUN: Would delete AMI: $ami_name ($ami_id)" >&2
            fi
        done
    else
        echo "No obsolete AMIs to delete." >&2
    fi
}

# Main
# echo "Profile: $PROFILE, Region: $REGION, DRY_RUN: $DRY_RUN, Keep History: $KEEP_HISTORY" >&2

# Get the active AMI for the provided template
active_ami=$(get_active_ami_for_template)
if [[ -n "$active_ami" ]]; then
    ami_name=$(get_ami_name "$active_ami")
    echo "Active AMI for template $TEMPLATE_NAME: $ami_name ($active_ami)" >&2
else
    echo "No active AMI found for template: $TEMPLATE_NAME" >&2
    exit 1
fi

# Get obsolete AMIs based on the active AMI
obsolete_amis=$(get_obsolete_amis "$active_ami")

# Print and delete the AMIs
if [[ $(echo "$obsolete_amis" | jq length) -gt "$KEEP_HISTORY" ]]; then
    echo "$obsolete_amis" | jq -r '.[] | "\(.Name) (\(.ID))"' >&2
    delete_obsolete_amis "$obsolete_amis"
else
    echo "No obsolete AMIs to delete." >&2
fi