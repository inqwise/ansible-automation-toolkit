#!/bin/bash

set -eu

# Function to display usage
usage() {
    echo "Usage: $0 --region <region> [--profile <profile>] [--toolkit-version <version>] [--make-default-version]"
    echo "Options:"
    echo "  --region                AWS region to search for AMIs (required)"
    echo "  --profile               AWS CLI profile to use (optional)"
    echo "  --toolkit-version       Version of the toolkit to use (optional, default: default)"
    echo "  --make-default-version  Flag to set the AMI as the default version (optional, default: false)"
    exit 1
}

# Initialize variables
PROFILE=""
REGION=""
TOOLKIT_VERSION="default"
MAKE_DEFAULT_VERSION=false

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --toolkit-version)
            TOOLKIT_VERSION="$2"
            shift 2
            ;;
        --make-default-version)
            MAKE_DEFAULT_VERSION=true
            shift 1
            ;;
        *)
            echo "Unknown parameter passed: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "$REGION" ]]; then
    echo "Error: --region is required."
    usage
fi

echo "Profile: ${PROFILE:-default}"
echo "Region: $REGION"
echo "Toolkit Version: $TOOLKIT_VERSION"
echo "Make Default Version: $MAKE_DEFAULT_VERSION"

echo "Fetching AMIs with tag 'amm:source_ami' and state 'available'..."
if [[ -n "$PROFILE" ]]; then
    amis=$(aws ec2 describe-images \
        --profile "$PROFILE" \
        --region "$REGION" \
        --owners self \
        --filters "Name=tag-key,Values=amm:source_ami" "Name=state,Values=available" \
        --query "Images[?!(Tags[?Key=='amm:template_status'])].{ImageId: ImageId, Name: Name, Tags: Tags}" \
        --output json)
else
    amis=$(aws ec2 describe-images \
        --region "$REGION" \
        --owners self \
        --filters "Name=tag-key,Values=amm:source_ami" "Name=state,Values=available" \
        --query "Images[?!(Tags[?Key=='amm:template_status'])].{ImageId: ImageId, Name: Name, Tags: Tags}" \
        --output json)
fi

echo "Raw AMIs output:"
echo "$amis" | jq .

echo "Processing AMIs..."
processed=$(echo "$amis" | jq -c '
    [
        .[] |
        {
            id: .ImageId,
            amiName: .Name,
            version: (
                (.Tags // []) 
                | map(select(.Key == "version")) 
                | .[0].Value // "N/A"
            )
        } |
        select(.version != "test-workflow" and .version != "N/A") |
        (.version as $v | .template_name = (.amiName | sub("-" + $v + "$"; "")))
    ]
    | group_by(.template_name)
    | map(
        sort_by(.version | split(".") | map(tonumber)) | reverse
        | to_entries
        | map(
            .value + { template_action: (if .key == 0 then "assign" else "skip" end) }
        )
    )
    | flatten
')

if [[ -z "$processed" || "$processed" == "[]" ]]; then
    echo "No available AMIs found matching the criteria."
    exit 0
fi

echo "Processed AMIs:"
echo "$processed" | jq .

# Apply Tags for related snapshots

# Define predefined tag keys
PREDEFINED_TAG_KEYS=("Name" "timestamp" "version" "app")

echo "Filtering predefined tags and tagging snapshots..."

echo "$processed" | jq -c '.[]' | while IFS= read -r ami; do
    ami_id=$(echo "$ami" | jq -r '.id')
    
    # Retrieve AMI tags
    if [[ -n "$PROFILE" ]]; then
        tags=$(aws ec2 describe-tags --profile "$PROFILE" --region "$REGION" --filters "Name=resource-id,Values=$ami_id" --query 'Tags' --output json)
    else
        tags=$(aws ec2 describe-tags --region "$REGION" --filters "Name=resource-id,Values=$ami_id" --query 'Tags' --output json)
    fi
    
    # Filter tags to predefined keys
    filtered_tags=$(echo "$tags" | jq -c --argjson keys "$(printf '%s\n' "${PREDEFINED_TAG_KEYS[@]}" | jq -R . | jq -s .)" '[.[] | select(.Key as $k | $keys | index($k))]')
    
    # Get snapshot IDs from AMI's block device mappings
    snapshot_ids=$(aws ec2 describe-images --image-ids "$ami_id" --region "$REGION" --query 'Images[].BlockDeviceMappings[].Ebs.SnapshotId' --output text)
    
    # Tag snapshots with filtered tags
    for snapshot_id in $snapshot_ids; do
        if [[ -n "$PROFILE" ]]; then
            aws ec2 create-tags --profile "$PROFILE" --region "$REGION" --resources "$snapshot_id" \
                --tags $(echo "$filtered_tags" | jq -r '.[] | "Key=\(.Key),Value=\(.Value)"' | paste -sd ' ')
        else
            aws ec2 create-tags --region "$REGION" --resources "$snapshot_id" \
                --tags $(echo "$filtered_tags" | jq -r '.[] | "Key=\(.Key),Value=\(.Value)"' | paste -sd ' ')
        fi
    done
done

# Handle skipped items
echo "Tagging skipped AMIs..."
echo "$processed" | jq -c '.[] | select(.template_action == "skip")' | while IFS= read -r item; do
    ami_id=$(echo "$item" | jq -r '.id')
    echo "Tagging AMI $ami_id as 'skipped'..."
    if [[ -n "$PROFILE" ]]; then
        aws ec2 create-tags \
            --profile "$PROFILE" \
            --region "$REGION" \
            --resources "$ami_id" \
            --tags Key=amm:template_status,Value=skipped
    else
        aws ec2 create-tags \
            --region "$REGION" \
            --resources "$ami_id" \
            --tags Key=amm:template_status,Value=skipped
    fi
done

assign_items=$(echo "$processed" | jq -c '.[] | select(.template_action == "assign")')

# Determine the update script
echo "Determining update script..."
if [[ -f "update_template_ami.sh" ]]; then
    UPDATE_SCRIPT="./update_template_ami.sh"
    echo "Using local update_template_ami.sh script."
else
    DEREGISTER_SCRIPT_URL="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/${TOOLKIT_VERSION}/update_template_ami.sh"
    TMP_SCRIPT="/tmp/update_template_ami.sh"
    echo "Downloading update_template_ami.sh from toolkit version $TOOLKIT_VERSION..."
    curl -sSL "$DEREGISTER_SCRIPT_URL" -o "$TMP_SCRIPT"
    chmod +x "$TMP_SCRIPT"
    UPDATE_SCRIPT="$TMP_SCRIPT"
    echo "Using remote update_template_ami.sh script."
fi

# Assign and tag assigned AMIs
echo "Assigning AMIs..."
echo "$assign_items" | while IFS= read -r item; do
    template_name=$(echo "$item" | jq -r '.template_name')
    new_ami_id=$(echo "$item" | jq -r '.id')
    version_description=$(echo "$item" | jq -r '.version')

    echo "Updating template '$template_name' with AMI '$new_ami_id' (Version: $version_description)..."
    if $MAKE_DEFAULT_VERSION; then
        bash "$UPDATE_SCRIPT" -t "$template_name" -a "$new_ami_id" -d "$version_description" -r "$REGION" -p "$PROFILE" -m
    else
        if [[ -n "$PROFILE" ]]; then
            bash "$UPDATE_SCRIPT" -t "$template_name" -a "$new_ami_id" -d "$version_description" -r "$REGION" -p "$PROFILE"
        else
            bash "$UPDATE_SCRIPT" -t "$template_name" -a "$new_ami_id" -d "$version_description" -r "$REGION"
        fi
    fi

    # Check if the update script succeeded
    if [[ $? -ne 0 ]]; then
        echo "Error: update_template_ami.sh failed for template '$template_name' with AMI '$new_ami_id'. Exiting."
        exit 1
    fi

    echo "Tagging AMI '$new_ami_id' as 'assigned'..."
    if [[ -n "$PROFILE" ]]; then
        aws ec2 create-tags \
            --profile "$PROFILE" \
            --region "$REGION" \
            --resources "$new_ami_id" \
            --tags Key=amm:template_status,Value=assigned
    else
        aws ec2 create-tags \
            --region "$REGION" \
            --resources "$new_ami_id" \
            --tags Key=amm:template_status,Value=assigned
    fi
done

echo "AMI assignment and tagging completed successfully."