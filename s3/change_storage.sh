#!/bin/bash

# Variables
BUCKET_NAME=""
PREFIX=""
AWS_PROFILE=""
AWS_REGION="us-east-1"
DRY_RUN=false
PERMANENTLY=false
RESTORE_DAYS=14
BATCH_SIZE=10

# Function to print usage
usage() {
  echo "Usage: $0 --bucket <bucket-name> --prefix <file-prefix> [--profile <aws-profile>] [--region <aws-region>] [--dry-run] [--permanently] [--restore-days <days>]"
  exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --bucket)
      BUCKET_NAME="$2"
      shift 2
      ;;
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    --profile)
      AWS_PROFILE="$2"
      shift 2
      ;;
    --region)
      AWS_REGION="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift 1
      ;;
    --permanently)
      PERMANENTLY=true
      RESTORE_DAYS=1 # Automatically set restore days to 1 when --permanently is provided
      shift 1
      ;;
    --restore-days)
      if [[ "$PERMANENTLY" == "true" ]]; then
        echo "Error: --restore-days cannot be used with --permanently."
        exit 1
      fi
      RESTORE_DAYS="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

# Validate arguments
if [[ -z "$BUCKET_NAME" || -z "$PREFIX" ]]; then
  usage
fi

# AWS CLI profile configuration
PROFILE_FLAG=""
if [[ -n "$AWS_PROFILE" ]]; then
  PROFILE_FLAG="--profile $AWS_PROFILE"
fi

# Confirm dry-run and permanent copy modes
if [[ "$DRY_RUN" == "true" ]]; then
  echo "Running in DRY-RUN mode. No changes will be applied."
else
  echo "Running in LIVE mode. Changes will be applied."
fi

if [[ "$PERMANENTLY" == "true" ]]; then
  echo "Objects will be permanently copied to STANDARD_IA after restore. Restore days set to 1."
else
  echo "Objects will only be restored temporarily for $RESTORE_DAYS days."
fi

# Enable immediate error handling
set -e

# Paginated listing and processing
CONTINUATION_TOKEN=""
echo "Listing objects with prefix '$PREFIX' in bucket '$BUCKET_NAME' in batches of $BATCH_SIZE..."

while true; do
  if [[ -n "$CONTINUATION_TOKEN" ]]; then
    RESPONSE=$(aws s3api list-objects-v2 \
      --bucket "$BUCKET_NAME" \
      --prefix "$PREFIX" \
      --region "$AWS_REGION" \
      $PROFILE_FLAG \
      --max-items "$BATCH_SIZE" \
      --continuation-token "$CONTINUATION_TOKEN" \
      --output json)
  else
    RESPONSE=$(aws s3api list-objects-v2 \
      --bucket "$BUCKET_NAME" \
      --prefix "$PREFIX" \
      --region "$AWS_REGION" \
      $PROFILE_FLAG \
      --max-items "$BATCH_SIZE" \
      --output json)
  fi

  # Extract continuation token
  CONTINUATION_TOKEN=$(echo "$RESPONSE" | jq -r '.NextContinuationToken // empty')

  # Extract object keys
  OBJECT_KEYS=($(echo "$RESPONSE" | jq -r '.Contents[] | .Key'))

  if [[ ${#OBJECT_KEYS[@]} -eq 0 && -z "$CONTINUATION_TOKEN" ]]; then
    echo "No more objects found in this batch. Exiting..."
    break
  fi

  echo "Processing ${#OBJECT_KEYS[@]} objects in this batch..."

  for OBJECT_KEY in "${OBJECT_KEYS[@]}"; do
    echo "Checking restore status for object: $OBJECT_KEY"

    # Check if object is already restored or being restored
    RESTORE_STATUS=$(aws s3api head-object --bucket "$BUCKET_NAME" --key "$OBJECT_KEY" $PROFILE_FLAG --region "$AWS_REGION" | jq -r '.Restore // empty')

    if [[ "$RESTORE_STATUS" =~ "ongoing-request=\"true\"" ]]; then
      echo "Object $OBJECT_KEY is already being restored. Skipping."
      continue
    elif [[ "$RESTORE_STATUS" =~ "ongoing-request=\"false\"" ]]; then
      echo "Object $OBJECT_KEY has already been restored. Skipping."
      continue
    fi

    if [[ "$DRY_RUN" == "false" ]]; then
      # Attempt to restore the object
      RESTORE_RESPONSE=$(aws s3api restore-object \
        --bucket "$BUCKET_NAME" \
        --key "$OBJECT_KEY" \
        --restore-request "{\"Days\": $RESTORE_DAYS, \"GlacierJobParameters\": {\"Tier\": \"Standard\"}}" \
        $PROFILE_FLAG \
        --region "$AWS_REGION" 2>&1 || true)

      if echo "$RESTORE_RESPONSE" | grep -q "Restore already in progress"; then
        echo "Restore already in progress for $OBJECT_KEY."
      elif echo "$RESTORE_RESPONSE" | grep -q "has been restored"; then
        echo "Object $OBJECT_KEY is already restored."
      else
        echo "Initiated restore for $OBJECT_KEY."
      fi
    else
      echo "DRY-RUN: Would restore object $OBJECT_KEY for $RESTORE_DAYS days."
    fi
  done

  # Break if continuation token is empty and batch is empty
  if [[ -z "$CONTINUATION_TOKEN" && ${#OBJECT_KEYS[@]} -eq 0 ]]; then
    echo "No more files to process. Exiting..."
    break
  fi
done

echo "Script completed."