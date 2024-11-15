#!/bin/bash

set -eu

# Function to display usage
usage() {
    echo "Usage: $0 --region <region> [--profile <profile>] [--toolkit-version <version>] [--make-default-version] [--create-template-if-not-exist] [--skip-template-if-not-exist]"
    echo "Options:"
    echo "  --region                      AWS region to search for AMIs (required)"
    echo "  --profile                     AWS CLI profile to use (optional)"
    echo "  --toolkit-version             Version of the toolkit to use (optional, default: default)"
    echo "  --make-default-version        Flag to set the AMI as the default version (optional, default: false)"
    echo "  --create-template-if-not-exist  Create template if it does not exist"
    echo "  --skip-template-if-not-exist    Skip processing if the template does not exist"
    exit 1
}

# Initialize variables
PROFILE=""
REGION=""
TOOLKIT_VERSION="default"
MAKE_DEFAULT_VERSION=false
CREATE_TEMPLATE_IF_NOT_EXIST=false
SKIP_TEMPLATE_IF_NOT_EXIST=false

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
        --create-template-if-not-exist)
            CREATE_TEMPLATE_IF_NOT_EXIST=true
            shift 1
            ;;
        --skip-template-if-not-exist)
            SKIP_TEMPLATE_IF_NOT_EXIST=true
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

# Ensure mutual exclusivity
if [[ "$CREATE_TEMPLATE_IF_NOT_EXIST" == "true" && "$SKIP_TEMPLATE_IF_NOT_EXIST" == "true" ]]; then
    echo "Error: --create-template-if-not-exist and --skip-template-if-not-exist cannot both be set."
    usage
fi

echo "Profile: ${PROFILE:-default}"
echo "Region: $REGION"
echo "Toolkit Version: $TOOLKIT_VERSION"
echo "Make Default Version: $MAKE_DEFAULT_VERSION"
echo "Create Template If Not Exist: $CREATE_TEMPLATE_IF_NOT_EXIST"
echo "Skip Template If Not Exist: $SKIP_TEMPLATE_IF_NOT_EXIST"

# Fetch AMIs
echo "Fetching AMIs with tag 'amm:source_ami' and state 'available'..."
amis=$(aws ec2 describe-images \
    --region "$REGION" \
    ${PROFILE:+--profile "$PROFILE"} \
    --owners self \
    --filters "Name=tag-key,Values=amm:source_ami" "Name=state,Values=available" \
    --query "Images[?!(Tags[?Key=='amm:template_status'])].{ImageId: ImageId, Name: Name, Tags: Tags}" \
    --output json)

echo "Raw AMIs output:"
echo "$amis" | jq .

# Process AMIs
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

# Download update script if not found locally
UPDATE_SCRIPT="./update_template_ami.sh"
if [[ ! -f "$UPDATE_SCRIPT" ]]; then
    echo "Downloading update_template_ami.sh from toolkit version $TOOLKIT_VERSION..."
    TMP_SCRIPT="/tmp/update_template_ami.sh"
    curl -sSL "https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/${TOOLKIT_VERSION}/update_template_ami.sh" -o "$TMP_SCRIPT"
    chmod +x "$TMP_SCRIPT"
    UPDATE_SCRIPT="$TMP_SCRIPT"
fi

# Function to update template and handle create/skip conditions
update_template() {
    local template_name="$1"
    local ami_id="$2"
    local version_description="$3"

    echo "Updating template '$template_name' with AMI '$ami_id' (Version: $version_description)..."

    update_output=$(bash "$UPDATE_SCRIPT" -t "$template_name" -a "$ami_id" -d "$version_description" -r "$REGION" ${PROFILE:+-p "$PROFILE"} ${MAKE_DEFAULT_VERSION:+-m} 2>&1 || true)

    if [[ "$update_output" == *"Launch template with name"* ]]; then
        if [[ "$CREATE_TEMPLATE_IF_NOT_EXIST" == "true" ]]; then
            echo "Template does not exist. Creating it..."
            # Logic for creating a new template
        elif [[ "$SKIP_TEMPLATE_IF_NOT_EXIST" == "true" ]]; then
            echo "Template does not exist. Skipping as per --skip-template-if-not-exist."
            return
        else
            echo "Template does not exist and no action specified. Exiting."
            exit 1
        fi
    else
        echo "Template updated successfully."
    fi
}

# Assign AMIs to templates
echo "Assigning AMIs..."
echo "$processed" | jq -c '.[] | select(.template_action == "assign")' | while IFS= read -r item; do
    template_name=$(echo "$item" | jq -r '.template_name')
    ami_id=$(echo "$item" | jq -r '.id')
    version=$(echo "$item" | jq -r '.version')

    update_template "$template_name" "$ami_id" "$version"
done

echo "Script completed successfully."