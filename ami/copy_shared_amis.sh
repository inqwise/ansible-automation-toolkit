#!/bin/bash
set -e  # Exit immediately if a command exits with a non-zero status

# ============================
# Configuration and Setup
# ============================

# Default values
SOURCE_ACCOUNT_ID=""
SOURCE_REGION=""
TARGET_REGION=""
PROFILE=""
LIMIT=0  # Default limit is 0 (no limit on source AMIs)
SOURCE_KMS_KEY_ID=""  # Optional KMS Key ID for encryption
TOOLKIT_VERSION="default"  # Default toolkit version
TAG_PREFIX="amm:"  # Prefix for all amm:source_* tags

# URL to download deregister_ami.sh if not present, based on toolkit version
DEREGISTER_SCRIPT_URL="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/${TOOLKIT_VERSION}/ami/deregister_ami.sh"

# Determine the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Path to deregister_ami.sh
DEREGISTER_SCRIPT="$SCRIPT_DIR/deregister_ami.sh"

# Regex to capture metadata from the description
DESCRIPTION_REGEX="^Image of ([a-z\-]+) version ([a-zA-Z\-\.0-9]+)( timestamp ([0-9]+))?$"

# Help message function
show_help() {
  echo "Usage: $0 --source-region <SOURCE_REGION> --region <TARGET_REGION> [--source-account-id <SOURCE_ACCOUNT_ID>] [--profile <PROFILE>] [--limit <LIMIT>] [--source-kms-key-id <KMS_KEY_ID>] [--toolkit-version <TOOLKIT_VERSION>]"
  exit 1
}

# ============================
# Function Definitions
# ============================

# Function to download deregister_ami.sh if it does not exist
download_deregister_script() {
  if [[ ! -f "$DEREGISTER_SCRIPT" ]]; then
    echo "deregister_ami.sh not found. Downloading from $DEREGISTER_SCRIPT_URL..."
    # Attempt to download using curl; fallback to wget if curl is not available
    if command -v curl >/dev/null 2>&1; then
      curl -fSL "$DEREGISTER_SCRIPT_URL" -o "$DEREGISTER_SCRIPT" || {
        echo "Error: Failed to download deregister_ami.sh using curl." >&2
        exit 1
      }
    elif command -v wget >/dev/null 2>&1; then
      wget -O "$DEREGISTER_SCRIPT" "$DEREGISTER_SCRIPT_URL" || {
        echo "Error: Failed to download deregister_ami.sh using wget." >&2
        exit 1
      }
    else
      echo "Error: Neither curl nor wget is available to download deregister_ami.sh." >&2
      exit 1
    fi

    # Make the script executable
    chmod +x "$DEREGISTER_SCRIPT" || {
      echo "Error: Failed to make deregister_ami.sh executable." >&2
      exit 1
    }
    echo "deregister_ami.sh downloaded and made executable."
  else
    echo "deregister_ami.sh already exists at $DEREGISTER_SCRIPT."
  fi
}

# ============================
# Parse Command-Line Arguments
# ============================

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --source-account-id)
      SOURCE_ACCOUNT_ID="$2"
      shift 2
      ;;
    --source-region)
      SOURCE_REGION="$2"
      shift 2
      ;;
    --region)
      TARGET_REGION="$2"
      shift 2
      ;;
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    --source-kms-key-id)
      SOURCE_KMS_KEY_ID="$2"
      shift 2
      ;;
    --toolkit-version)
      TOOLKIT_VERSION="$2"
      shift 2
      ;;
    *)
      show_help
      ;;
  esac
done

# Update DEREGISTER_SCRIPT_URL if TOOLKIT_VERSION was provided and not default
if [[ "$TOOLKIT_VERSION" != "default" ]]; then
  DEREGISTER_SCRIPT_URL="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/${TOOLKIT_VERSION}/ami/deregister_ami.sh"
fi

# ============================
# Validate Required Arguments
# ============================

missing_params=0

if [[ -z "$SOURCE_REGION" ]]; then
  echo "Error: --source-region is required."
  missing_params=1
fi

if [[ -z "$TARGET_REGION" ]]; then
  echo "Error: --region is required."
  missing_params=1
fi

if [[ $missing_params -eq 1 ]]; then
  echo "Please provide all required parameters."
  show_help
  exit 1
fi

# ============================
# Ensure deregister_ami.sh is Available
# ============================

download_deregister_script

# ============================
# Retrieve AWS Account Information
# ============================

# Collect current account ID after parsing arguments, using the specified profile if provided
CURRENT_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text ${PROFILE:+--profile "$PROFILE"})
echo "Current AWS Account ID: $CURRENT_ACCOUNT_ID"

if [[ -z "$SOURCE_ACCOUNT_ID" ]]; then
  SOURCE_ACCOUNT_ID="$CURRENT_ACCOUNT_ID"
fi

# ============================
# Fetch and Process Source AMIs
# ============================

echo "Retrieving AMIs from source account: $SOURCE_ACCOUNT_ID in region: $SOURCE_REGION with profile: ${PROFILE:-default}..."
FETCH_SOURCE_AMIS="aws ec2 describe-images --owners \"$SOURCE_ACCOUNT_ID\" --region \"$SOURCE_REGION\" ${PROFILE:+--profile \"$PROFILE\"} --query \"sort_by(Images, &Name)[].{Name:Name, ImageId:ImageId, CreationDate:CreationDate, Description:Description, Tags:Tags}\" --output json"

# Add --max-items if LIMIT is greater than zero
if [[ "$LIMIT" -gt 0 ]]; then
  FETCH_SOURCE_AMIS+=" --max-items $LIMIT"
fi

# Capture source AMIs as a JSON array
SOURCE_AMIS=$(eval "$FETCH_SOURCE_AMIS")

# Check if source AMI details were fetched successfully
if [[ -z "$SOURCE_AMIS" || "$SOURCE_AMIS" == "[]" ]]; then
  echo "No AMIs found in source region $SOURCE_REGION for account $SOURCE_ACCOUNT_ID."
  exit 0
fi

# Display source AMI details
echo "Source AMIs retrieved and sorted by Name:"
echo "$SOURCE_AMIS" | jq '.'
echo

# Convert source AMI names to a comma-separated string for filtering
SOURCE_AMI_NAMES=$(echo "$SOURCE_AMIS" | jq -r '.[].Name' | paste -sd "," -)
echo "Source AMI Names for filtering: $SOURCE_AMI_NAMES"
echo

# ============================
# Filter Target AMIs
# ============================

echo "Identifying target AMIs in region $TARGET_REGION with names matching source AMIs and statuses 'available' or 'pending'..."
TARGET_AMIS=$(aws ec2 describe-images \
  --owners "self" \
  --region "$TARGET_REGION" \
  ${PROFILE:+--profile "$PROFILE"} \
  --filters "Name=name,Values=$SOURCE_AMI_NAMES" \
           "Name=state,Values=available,pending" \
  --query "Images[].{Name:Tags[?Key=='Name']|[0].Value, ImageId:ImageId, State:State, CreationDate:CreationDate, Description:Description}" \
  --output json)

# Display initial filtered target AMIs
echo "Target AMIs in region $TARGET_REGION after initial filtering by names and status:"
echo "$TARGET_AMIS" | jq '.'
echo

# Apply additional filtering on target AMIs based on each source AMI's name and creation date
echo "Applying additional filtering to target AMIs based on specific name and creation date for each source AMI..."
FINAL_TARGET_AMIS=$(echo "$TARGET_AMIS" | jq --argjson source_amis "$SOURCE_AMIS" '
  map(select(
    .Name as $name |
    .CreationDate as $target_creation |
    any($source_amis[]; .Name == $name and .CreationDate < $target_creation)
  ))
')

# Display final filtered target AMIs
echo "Final filtered target AMIs in region $TARGET_REGION after matching with individual source AMI names and creation dates:"
echo "$FINAL_TARGET_AMIS" | jq '.'
echo

# Exclude source AMIs that already exist in the target region
echo "Excluding source AMIs with names already present in filtered target AMIs..."
FILTERED_SOURCE_AMIS=$(echo "$SOURCE_AMIS" | jq --argjson final_target_amis "$FINAL_TARGET_AMIS" '
  map(select(.Name as $name | all($final_target_amis[]; .Name != $name)))
')

# Display final filtered source AMIs for copying
echo "Source AMIs to be copied to target region $TARGET_REGION after excluding those already present:"
echo "$FILTERED_SOURCE_AMIS" | jq '.'
echo

# ============================
# Initialize JSON Array for New AMIs
# ============================

# Initialize an empty JSON array to store details of new AMIs
NEW_AMIS='[]'

# ============================
# Initiate AMI Copy Process
# ============================

echo "Initiating AMI copy process from source region $SOURCE_REGION to target region $TARGET_REGION..."

# Use process substitution to avoid subshell and preserve NEW_AMIS updates
while read -r ami; do
  name=$(echo "$ami" | jq -r '.Name')
  image_id=$(echo "$ami" | jq -r '.ImageId')
  description=$(echo "$ami" | jq -r '.Description')

  # Check if an AMI with the same name already exists in the target region
  existing_ami=$(aws ec2 describe-images \
    --owners "self" \
    --region "$TARGET_REGION" \
    ${PROFILE:+--profile "$PROFILE"} \
    --filters "Name=name,Values=$name" \
    --query "Images[0].ImageId" \
    --output text)

  if [[ "$existing_ami" != "None" && -n "$existing_ami" ]]; then
    echo "Warning: $existing_ami with name '$name' already exists in region $TARGET_REGION. Deregistering the existing AMI."

    # **Call to deregister_ami.sh**
    echo "Deregistering existing AMI with Image ID '$existing_ami' in region '$TARGET_REGION'..."
    bash "$DEREGISTER_SCRIPT" --ami "$existing_ami" --region "$TARGET_REGION" ${PROFILE:+--profile "$PROFILE"} || {
      echo "Error: Failed to deregister AMI '$existing_ami'. Skipping copy for this AMI."
      continue
    }

    echo "Successfully deregistered AMI '$existing_ami'. Proceeding to copy the new AMI."
    # Proceed to copy the new AMI after successful deregistration
  fi

  # Copy the AMI with optional encryption
  echo "Copying AMI '$name' (ImageId: $image_id) from $SOURCE_REGION to $TARGET_REGION..."
  copy_command=("aws ec2 copy-image \
    --source-region \"$SOURCE_REGION\" \
    --source-image-id \"$image_id\" \
    --region \"$TARGET_REGION\" \
    ${PROFILE:+--profile \"$PROFILE\"} \
    --name \"$name\" \
    --description \"$description\"")

  if [[ -n "$SOURCE_KMS_KEY_ID" ]]; then
    copy_command+=("--encrypted" "--kms-key-id" "$SOURCE_KMS_KEY_ID")
  fi

  # Execute the copy command and capture the new AMI ID
  new_ami_id=$(eval "${copy_command[@]} --query 'ImageId' --output text")

  # ============================
  # Retrieve and Prepare Tags
  # ============================

  # Parse the tags JSON array
  
  # Try to match the description with the regex
  if [[ $description =~ $DESCRIPTION_REGEX ]]; then
    # Extract matched groups
    app="${BASH_REMATCH[1]}"
    version="${BASH_REMATCH[2]}"
    timestamp="${BASH_REMATCH[4]}"

    # Validate required fields
    if [[ -z "$app" || -z "$version" ]]; then
      echo "Error: Missing required fields in description for AMI ID $ami_id. 'app' and 'version' must be present."
      exit 1
    fi

    # Prepare tags based on extracted fields
    declare -a tags_array=()
    tags_array+=("Key=Name,Value=${app}-${version}")
    tags_array+=("Key=app,Value=$app")
    tags_array+=("Key=version,Value=$version")

    # Only add timestamp if it's available
    if [[ -n "$timestamp" ]]; then
      tags_array+=("Key=timestamp,Value=$timestamp")
    fi

    # Display generated tags
    echo "Generated tags for AMI ID $ami_id:"
    for tag in "${tags_array[@]}"; do
      echo "  $tag"
    done
  else
    echo "Error: Description format does not match expected pattern for AMI ID $ami_id."
    exit 1
  fi

  # Add amm:source_ami tag
  tags_array+=("Key=${TAG_PREFIX}source_ami,Value=$image_id")

  # Add amm:source_region tag
  tags_array+=("Key=${TAG_PREFIX}source_region,Value=$SOURCE_REGION")

  # Conditionally add amm:source_account tag if SOURCE_ACCOUNT_ID != CURRENT_ACCOUNT_ID
  if [[ "$SOURCE_ACCOUNT_ID" != "$CURRENT_ACCOUNT_ID" ]]; then
    tags_array+=("Key=${TAG_PREFIX}source_account,Value=$SOURCE_ACCOUNT_ID")
  fi

  # Convert tags_array to a space-separated string
  tags_string=$(printf " %s" "${tags_array[@]}")

  # Tag the new AMI with all tags
  echo "Tagging new AMI $new_ami_id with all source tags and additional tags..."
  aws ec2 create-tags \
    --resources "$new_ami_id" \
    --region "$TARGET_REGION" \
    ${PROFILE:+--profile "$PROFILE"} \
    --tags $tags_string

  echo "Copying process for AMI '$name' has been initialized. Check later for the completion status of AMI ID $new_ami_id."

  # Append the new AMI details to the JSON array
  NEW_AMIS=$(echo "$NEW_AMIS" | jq --arg ami_id "$new_ami_id" --arg ami_name "$name" --arg ami_description "$description" \
    '. + [{ImageId: $ami_id, Name: $ami_name, Description: $ami_description}]')
done < <(echo "$FILTERED_SOURCE_AMIS" | jq -c '.[]')

# ============================
# Save and Print the Collected New AMIs JSON Array
# ============================

# Define the output file path
OUTPUT_FILE="$SCRIPT_DIR/new_amis.json"

# Save the JSON array to the file
echo "$NEW_AMIS" | jq '.' > "$OUTPUT_FILE"
echo "New AMI details saved to $OUTPUT_FILE."

# Print the JSON array
echo "Newly Copied AMIs:"
echo "$NEW_AMIS" | jq '.'

echo "AMI copy process completed."