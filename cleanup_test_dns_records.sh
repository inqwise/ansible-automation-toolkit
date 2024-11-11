#!/bin/bash
set -euo pipefail

# Default Variables
PROFILE=""  # AWS CLI profile (optional)
HOSTED_ZONE_NAME=""
DRY_RUN=false

# Usage function to display help
usage() {
    echo "Usage: $0 [-z <hosted_zone_name>] [-p <aws_profile>] [--dry-run]"
    echo ""
    echo "Options:"
    echo "  -z, --zone         Hosted Zone name (optional; if not provided, all zones will be processed)"
    echo "  -p, --profile      AWS CLI profile (optional; if not provided, the default profile is used)"
    echo "      --dry-run      Dry run mode, shows what would be deleted"
    exit 1
}

# Check for required dependencies
command -v aws >/dev/null 2>&1 || { echo "AWS CLI is required but not installed. Aborting."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required but not installed. Aborting."; exit 1; }

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -z|--zone)
            HOSTED_ZONE_NAME="$2"
            shift
            ;;
        -p|--profile)
            PROFILE="--profile $2"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        *)
            echo "Unknown parameter: $1"
            usage
            ;;
    esac
    shift
done

# Function to get all hosted zone IDs if no specific zone is provided
get_all_hosted_zone_ids() {
    aws route53 list-hosted-zones $PROFILE --query "HostedZones[].{Id:Id,Name:Name}" --output json | \
    jq -r '.[] | "\(.Id | split("/")[2]) \(.Name)"'
}

# Function to get the hosted zone ID by name
get_hosted_zone_id() {
    local zone_name="${1%?}."  # Ensure zone name ends with a dot
    aws route53 list-hosted-zones $PROFILE --query "HostedZones[?Name == '${zone_name}'].Id" --output text | cut -d'/' -f3
}

# Function to delete records containing '-test'
delete_test_records() {
    local hosted_zone_id="$1"
    local record_name="$2"
    local record_type="$3"
    local ttl="$4"
    local resource_records="$5"

    echo "Deleting record: $record_name of type $record_type from Hosted Zone ID: $hosted_zone_id"

    if [ "$DRY_RUN" = false ]; then
        # Create a temporary file for the change batch
        temp_file=$(mktemp)
        cat > "$temp_file" << EOF
{
    "Changes": [
        {
            "Action": "DELETE",
            "ResourceRecordSet": {
                "Name": "$record_name",
                "Type": "$record_type",
                "TTL": $ttl,
                "ResourceRecords": $resource_records
            }
        }
    ]
}
EOF

        # Delete the record
        aws route53 change-resource-record-sets \
            --hosted-zone-id "$hosted_zone_id" \
            --change-batch "file://$temp_file" \
            $PROFILE

        # Clean up
        rm -f "$temp_file"
    else
        echo "Dry run: $record_name of type $record_type from Hosted Zone ID: $hosted_zone_id would have been deleted."
    fi
}

# Function to process all records in a hosted zone that match '-test'
process_zone_records() {
    local hosted_zone_id="$1"
    local hosted_zone_name="$2"

    echo "Fetching Route 53 records for hosted zone: $hosted_zone_name ($hosted_zone_id)..."
    records=$(aws route53 list-resource-record-sets --hosted-zone-id "$hosted_zone_id" $PROFILE --query 'ResourceRecordSets[?contains(Name, `-test`)]' --output json)

    if [ "$(echo "$records" | jq length)" -eq 0 ]; then
        echo "No matching records found in hosted zone: $hosted_zone_name"
    else
        echo "$records" | jq -c '.[]' | while read -r record; do
            record_name=$(echo "$record" | jq -r '.Name')
            record_type=$(echo "$record" | jq -r '.Type')
            ttl=$(echo "$record" | jq -r '.TTL')
            resource_records=$(echo "$record" | jq -c '.ResourceRecords')

            if [[ "$resource_records" == "null" ]]; then
                echo "Skipping alias or incomplete record: $record_name"
            else
                delete_test_records "$hosted_zone_id" "$record_name" "$record_type" "$ttl" "$resource_records"
            fi
        done
    fi
}

# Main execution logic
if [[ -n "$HOSTED_ZONE_NAME" ]]; then
    # If a specific hosted zone is provided
    HOSTED_ZONE_ID=$(get_hosted_zone_id "$HOSTED_ZONE_NAME")

    if [ -z "$HOSTED_ZONE_ID" ]; then
        echo "Hosted zone not found: $HOSTED_ZONE_NAME"
        exit 1
    fi

    process_zone_records "$HOSTED_ZONE_ID" "$HOSTED_ZONE_NAME"
else
    # If no specific hosted zone is provided, process all zones
    echo "No hosted zone provided, processing all hosted zones..."
    all_zones=$(get_all_hosted_zone_ids)

    if [ -z "$all_zones" ]; then
        echo "No hosted zones found."
        exit 1
    fi

    while IFS= read -r line; do
        zone_id=$(echo "$line" | awk '{print $1}')
        zone_name=$(echo "$line" | awk '{print $2}')
        process_zone_records "$zone_id" "$zone_name"
    done <<< "$all_zones"
fi

echo "Completed."