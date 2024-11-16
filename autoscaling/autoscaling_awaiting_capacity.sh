#!/bin/bash

# Fail immediately on any error
set -e

# Usage function
usage() {
    echo "Usage: $0 --region <region> [--profile <profile>]"
    echo "       Lists Auto Scaling groups in awaiting capacity state with their name and ID in JSON format."
    exit 1
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --region) REGION="$2"; shift ;;
        --profile) PROFILE="--profile $2"; shift ;;
        *) echo "Unknown parameter: $1"; usage ;;
    esac
    shift
done

# Validate required arguments
if [[ -z "$REGION" ]]; then
    echo "Error: --region is required."
    usage
fi

# Function to list awaiting capacity Auto Scaling groups
list_awaiting_capacity() {
    aws autoscaling describe-auto-scaling-groups --region "$REGION" $PROFILE \
        --query "AutoScalingGroups[?DesiredCapacity > \`0\` && CurrentCapacity < DesiredCapacity].{Name: AutoScalingGroupName, ID: AutoScalingGroupARN}" \
        --output json
}

# Get and print awaiting capacity Auto Scaling groups
echo "Awaiting Capacity Auto Scaling Groups (Name, ID):"
list_awaiting_capacity