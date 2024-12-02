#!/bin/bash

# Usage: ./detect_glacier_file_paths.sh --bucket <bucket-name> [--prefix <prefix>] [--profile <profile-name>]

set -euo pipefail

# Function to print usage information
usage() {
    echo "Usage: $0 --bucket <bucket-name> [--prefix <prefix>] [--profile <profile-name>]"
    exit 1
}

# Parse arguments
BUCKET_NAME=""
START_PREFIX=""
PROFILE_OPTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bucket)
            BUCKET_NAME="$2"
            shift 2
            ;;
        --prefix)
            START_PREFIX="$2"
            shift 2
            ;;
        --profile)
            PROFILE_OPTION="--profile $2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            ;;
    esac
done

# Ensure bucket name is provided
if [[ -z "$BUCKET_NAME" ]]; then
    echo "Error: --bucket is required."
    usage
fi

# Function to check for Glacier storage class objects in a prefix
check_glacier_in_prefix() {
    local prefix="$1"
    echo "Checking prefix: ${prefix}"

    # List objects and filter by Glacier storage class
    glacier_file=$(aws s3api list-objects-v2 \
        --bucket "$BUCKET_NAME" \
        --prefix "$prefix" \
        $PROFILE_OPTION \
        --query 'Contents[?StorageClass==`GLACIER`].[Key]' \
        --output text)

    if [[ -n "$glacier_file" ]]; then
        echo "Prefix with Glacier storage found: $prefix"
        echo "File path: $glacier_file"
        return 0
    fi

    return 1
}

# Get all prefixes in the bucket (or starting from the given prefix)
echo "Retrieving prefixes..."
prefixes=$(aws s3api list-objects-v2 \
    --bucket "$BUCKET_NAME" \
    --prefix "$START_PREFIX" \
    $PROFILE_OPTION \
    --delimiter "/" \
    --query 'CommonPrefixes[].Prefix' \
    --output text)

if [[ -z "$prefixes" ]]; then
    echo "No prefixes found in bucket $BUCKET_NAME with prefix $START_PREFIX."
    exit 0
fi

# Iterate over prefixes and check for Glacier objects
for prefix in $prefixes; do
    if check_glacier_in_prefix "$prefix"; then
        exit 0
    fi
done

echo "No files in Glacier storage found in any prefix."