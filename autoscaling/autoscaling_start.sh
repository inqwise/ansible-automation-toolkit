#!/bin/bash

# Usage function
usage() {
    echo "Usage: $0 --region <region> [--profile <profile>] --autoscaling-names <comma-separated-names> [--capacity <value>]"
    echo "       If --autoscaling-names is not provided, lists all stopped autoscaling groups alphabetically."
    exit 1
}

# Default capacity
DEFAULT_CAPACITY=1

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --region) REGION="$2"; shift ;;
        --profile) PROFILE="--profile $2"; shift ;;
        --autoscaling-names) AUTOSCALING_NAMES="$2"; shift ;;
        --capacity) CAPACITY="$2"; shift ;;
        *) echo "Unknown parameter: $1"; usage ;;
    esac
    shift
done

# Validate required arguments
if [[ -z "$REGION" ]]; then
    echo "Error: --region is required."
    usage
fi

# Set capacity
CAPACITY=${CAPACITY:-$DEFAULT_CAPACITY}

# Function to list stopped autoscaling groups
list_stopped_autoscaling_groups() {
    aws autoscaling describe-auto-scaling-groups --region "$REGION" $PROFILE \
        --query "AutoScalingGroups[?DesiredCapacity==\`0\`].AutoScalingGroupName" --output text | tr '\t' '\n' | sort | tr '\n' ','
}

# If no autoscaling names provided, list stopped autoscaling groups
if [[ -z "$AUTOSCALING_NAMES" ]]; then
    echo "Stopped Auto Scaling Groups:"
    STOPPED_GROUPS=$(list_stopped_autoscaling_groups)
    echo "${STOPPED_GROUPS%,}" # Remove trailing comma
    exit 0
fi

# Start each specified autoscaling group
IFS=',' read -r -a ASG_ARRAY <<< "$AUTOSCALING_NAMES"

for ASG_NAME in "${ASG_ARRAY[@]}"; do
    echo "Processing Auto Scaling Group: $ASG_NAME"

    CURRENT_CAPACITY=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" $PROFILE \
        --auto-scaling-group-names "$ASG_NAME" \
        --query "AutoScalingGroups[0].DesiredCapacity" --output text)

    if [[ "$CURRENT_CAPACITY" == "None" ]]; then
        echo "Error: Auto Scaling Group $ASG_NAME not found." >&2
        exit 1
    fi

    if [[ "$CURRENT_CAPACITY" -eq 0 ]]; then
        echo "Auto Scaling Group $ASG_NAME is stopped. Updating capacities to $CAPACITY."
        aws autoscaling update-auto-scaling-group --region "$REGION" $PROFILE \
            --auto-scaling-group-name "$ASG_NAME" \
            --min-size "$CAPACITY" \
            --max-size "$CAPACITY" \
            --desired-capacity "$CAPACITY" || exit 1
        echo "Updated $ASG_NAME successfully."
    else
        echo "Auto Scaling Group $ASG_NAME is already running with DesiredCapacity=$CURRENT_CAPACITY."
    fi
done