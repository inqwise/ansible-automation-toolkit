#!/bin/bash

# Print usage and exit
usage() {
  echo "Usage: $0 --region <region> [--profile <profile>] [--keep-history <number>] [--limit <number>]"
  exit 1
}

# Error handling
set -e

# Default values
PROFILE=""
REGION=""
KEEP_HISTORY=3  # Default value for KEEP_HISTORY
TOOLKIT_VERSION=${TOOLKIT_VERSION:-default}
DEREGISTER_SCRIPT_URL="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/${TOOLKIT_VERSION}/ami/deregister_ami.sh"
DEREGISTER_SCRIPT="./deregister_ami.sh"
LIMIT=0  # Default value for limit (0 = no limit)

# Download deregister_ami.sh if it doesn't exist locally
if [[ ! -f "$DEREGISTER_SCRIPT" ]]; then
  echo "Local version of deregister_ami.sh not found. Downloading from $DEREGISTER_SCRIPT_URL..."
  curl -o "$DEREGISTER_SCRIPT" "$DEREGISTER_SCRIPT_URL"
  chmod +x "$DEREGISTER_SCRIPT"
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      REGION="$2"
      shift 2
      ;;
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --keep-history)
      KEEP_HISTORY="$2"
      shift 2
      ;;
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      ;;
  esac
done

# Validate mandatory region argument
if [[ -z "$REGION" ]]; then
  echo "Error: Region is required."
  usage
fi

# Set profile argument if provided
PROFILE_ARG=""
if [[ -n "$PROFILE" ]]; then
  PROFILE_ARG="--profile $PROFILE"
  # Validate profile by testing a simple AWS CLI command
  if ! aws sts get-caller-identity $PROFILE_ARG >/dev/null 2>&1; then
    echo "Error: Invalid AWS profile '$PROFILE'."
    exit 1
  fi
fi

# Fetch AMIs with specified filters
AMIS_JSON=$(aws ec2 describe-images \
  --region "$REGION" $PROFILE_ARG \
  --owners self \
  --filters "Name=state,Values=available" \
  --query 'Images[*].{app: (Tags[?Key==`app`].Value | [0]), amiName: Name, amiId: ImageId, version: (Tags[?Key==`version`].Value | [0]), creationDate: CreationDate}' \
  --output json)

# Process and flatten, adding priority and filtering by KEEP_HISTORY, then apply LIMIT only on groups with more items than KEEP_HISTORY
echo "Processing AMIs by app group with limit $LIMIT..."

AMIS_TO_DEREGISTER=$(echo "$AMIS_JSON" | jq -r --argjson keep_history "$KEEP_HISTORY" --argjson limit "$LIMIT" '
  group_by(.app) |
  map(select(length > $keep_history)) | 
  if $limit > 0 then .[:$limit] else . end |
  map(
    sort_by(.version == "test-workflow", .creationDate) | reverse |
    to_entries |
    map({priority: (.key + 1)} + .value)
  ) | 
  flatten |
  map(select(.priority > $keep_history))')

# Debug output to show processed groups and filtered items
echo "Filtered items to be deregistered (debug):"
echo "$AMIS_TO_DEREGISTER" | jq '.[]'

# Loop through each AMI to deregister and call the deregister_ami.sh script
echo "$AMIS_TO_DEREGISTER" | jq -c '.[]' | while read -r ami; do
  ami_id=$(echo "$ami" | jq -r '.amiId')
  app=$(echo "$ami" | jq -r '.app')
  ami_name=$(echo "$ami" | jq -r '.amiName')
  version=$(echo "$ami" | jq -r '.version')
  creation_date=$(echo "$ami" | jq -r '.creationDate')
  priority=$(echo "$ami" | jq -r '.priority')

  # Print details of the AMI being deregistered
  echo "Deregistering AMI:"
  echo "  App: $app"
  echo "  Name: $ami_name"
  echo "  ID: $ami_id"
  echo "  Version: $version"
  echo "  Creation Date: $creation_date"
  echo "  Priority: $priority"

  # Call the deregister_ami.sh script with bash
  bash "$DEREGISTER_SCRIPT" --ami "$ami_id" --region "$REGION" $PROFILE_ARG
done

# Completion message
echo "Deregistration process completed. All AMIs with priority greater than $KEEP_HISTORY have been processed."