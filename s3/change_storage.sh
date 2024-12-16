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
STATE_FILE="restore_state.json"
START_AFTER=""

# Function to print usage
usage() {
  echo "Usage: $0 --bucket <bucket-name> --prefix <file-prefix> [--profile <aws-profile>] [--region <aws-region>] [--dry-run] [--permanently] [--restore-days <days>] [--start-after <filename>]"
  exit 1
}

# Load state
load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    echo "Loading previous state from $STATE_FILE..."
    CONTINUATION_TOKEN=$(jq -r '.continuation_token // empty' "$STATE_FILE")
    mapfile -t PROCESSED_KEYS < <(jq -r '.processed_keys[]' "$STATE_FILE")
  else
    CONTINUATION_TOKEN=""
    PROCESSED_KEYS=()
  fi
}

# Save state
save_state() {
  echo "Saving state to $STATE_FILE..."
  PROCESSED_KEYS_JSON=$(printf '%s\n' "${PROCESSED_KEYS[@]}" | jq -R . | jq -s .)
  jq -n \
    --arg continuation_token "$CONTINUATION_TOKEN" \
    --argjson processed_keys "$PROCESSED_KEYS_JSON" \
    '{continuation_token: $continuation_token, processed_keys: $processed_keys}' > "$STATE_FILE"
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
      RESTORE_DAYS=1
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
    --start-after)
      START_AFTER="$2"
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

# Confirm modes
echo "Running in $([[ "$DRY_RUN" == "true" ]] && echo 'DRY-RUN' || echo 'LIVE') mode."
echo "$([[ "$PERMANENTLY" == "true" ]] && echo 'PERMANENT mode' || echo "Temporary restore mode for $RESTORE_DAYS days")."

# Enable immediate error handling
set -e

# If a start-after key is provided, we won't rely on previous state
if [[ -n "$START_AFTER" ]]; then
  echo "Starting after $START_AFTER. Previous state will not be used."
  CONTINUATION_TOKEN=""
  PROCESSED_KEYS=()
else
  # Load previous state if available
  load_state
fi

# Paginated listing and processing
echo "Listing objects with prefix '$PREFIX' in bucket '$BUCKET_NAME' in batches of $BATCH_SIZE..."

while true; do
  LIST_ARGS=()
  
  if [[ -n "$CONTINUATION_TOKEN" ]]; then
    LIST_ARGS+=(--continuation-token "$CONTINUATION_TOKEN")
  elif [[ -n "$START_AFTER" ]]; then
    LIST_ARGS+=(--start-after "$START_AFTER")
  fi

  RESPONSE=$(aws s3api list-objects-v2 \
    --bucket "$BUCKET_NAME" \
    --prefix "$PREFIX" \
    --region "$AWS_REGION" \
    $PROFILE_FLAG \
    --max-keys "$BATCH_SIZE" \
    "${LIST_ARGS[@]}" \
    --output json)

  CONTINUATION_TOKEN=$(echo "$RESPONSE" | jq -r '.NextContinuationToken // empty')
  OBJECT_KEYS=($(echo "$RESPONSE" | jq -r '.Contents[]?.Key'))

  if [[ ${#OBJECT_KEYS[@]} -eq 0 ]]; then
    echo "No objects found in this batch."
    if [[ -z "$CONTINUATION_TOKEN" ]]; then
      break
    else
      continue
    fi
  fi

  echo "Processing ${#OBJECT_KEYS[@]} objects in this batch..."

  for OBJECT_KEY in "${OBJECT_KEYS[@]}"; do
    # Skip if already processed
    if [[ " ${PROCESSED_KEYS[@]} " =~ " ${OBJECT_KEY} " ]]; then
      echo "Object $OBJECT_KEY already processed. Skipping."
      continue
    fi

    echo "Checking storage class for object: $OBJECT_KEY"
    STORAGE_CLASS=$(aws s3api head-object --bucket "$BUCKET_NAME" --key "$OBJECT_KEY" $PROFILE_FLAG --region "$AWS_REGION" | jq -r '.StorageClass // "STANDARD"')

    if [[ "$STORAGE_CLASS" != "GLACIER" && "$STORAGE_CLASS" != "DEEP_ARCHIVE" ]]; then
      echo "Object $OBJECT_KEY does not require restoration (Storage Class: $STORAGE_CLASS). Skipping."
      PROCESSED_KEYS+=("$OBJECT_KEY")
      save_state
      continue
    fi

    echo "Checking restore status for object: $OBJECT_KEY"
    RESTORE_STATUS=$(aws s3api head-object --bucket "$BUCKET_NAME" --key "$OBJECT_KEY" $PROFILE_FLAG --region "$AWS_REGION" | jq -r '.Restore // empty')

    if [[ "$RESTORE_STATUS" =~ "ongoing-request=\"true\"" ]]; then
      echo "Object $OBJECT_KEY is already being restored. Skipping."
      PROCESSED_KEYS+=("$OBJECT_KEY")
      save_state
      continue
    elif [[ "$RESTORE_STATUS" =~ "ongoing-request=\"false\"" ]]; then
      echo "Object $OBJECT_KEY has already been restored. Skipping."
      PROCESSED_KEYS+=("$OBJECT_KEY")
      save_state
      continue
    fi

    if [[ "$DRY_RUN" == "false" ]]; then
      aws s3api restore-object \
        --bucket "$BUCKET_NAME" \
        --key "$OBJECT_KEY" \
        --restore-request "{\"Days\": $RESTORE_DAYS, \"GlacierJobParameters\": {\"Tier\": \"Expedited\"}}" \
        $PROFILE_FLAG \
        --region "$AWS_REGION" \
        && echo "Restore initiated for $OBJECT_KEY."
    else
      echo "DRY-RUN: Would restore object $OBJECT_KEY for $RESTORE_DAYS days."
    fi

    PROCESSED_KEYS+=("$OBJECT_KEY")
    save_state
  done

  if [[ -z "$CONTINUATION_TOKEN" ]]; then
    echo "No more files to process. Exiting..."
    break
  fi
done

# Optional cleanup: comment out or remove if you want to keep the state
# rm -f "$STATE_FILE"
echo "Script completed."