#!/bin/bash

# Fail immediately on any error
set -e

# Usage function
usage() {
    echo "Usage: $0 --region <region> [--profile <profile>] [--autoscaling-names <comma-separated-names>] [--skip-matching <true|false>]"
    echo "       Refreshes the specified Auto Scaling groups. If --autoscaling-names is not provided, lists filtered Auto Scaling groups alphabetically."
    echo "       Default: --skip-matching=true"
    exit 1
}

# Defaults
SKIP_MATCHING=true

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --region) REGION="$2"; shift ;;
        --profile) PROFILE="--profile $2"; shift ;;
        --autoscaling-names) AUTOSCALING_NAMES="$2"; shift ;;
        --skip-matching) SKIP_MATCHING="$2"; shift ;;
        *) echo "Unknown parameter: $1"; usage ;;
    esac
    shift
done

# Validate required arguments
if [[ -z "$REGION" ]]; then
    echo "Error: --region is required."
    usage
fi

# Function to list filtered Auto Scaling groups
list_autoscaling_groups() {
    aws autoscaling describe-auto-scaling-groups --region "$REGION" $PROFILE \
        --query "AutoScalingGroups" --output json | \
    jq -r '
        map(
            select(
                (.DesiredCapacity > 0) and
                (.RefreshStatus.RefreshInProgress | not) and
                ([.Instances[].ProtectedFromScaleIn] | all(. == false))
            )
        ) |
        sort_by(.AutoScalingGroupName) |
        .[].AutoScalingGroupName
    ' | tr '\n' ',' | sed 's/,$//'
}

# Debugging: Capture AWS CLI output if jq fails
debug_list_autoscaling_groups() {
    OUTPUT=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" $PROFILE --query "AutoScalingGroups" --output json)
    echo "$OUTPUT" > debug_autoscaling_output.json
    echo "Filtered Auto Scaling Groups:"
    echo "$OUTPUT" | jq -r '
        map(
            select(
                (.DesiredCapacity > 0) and
                (.RefreshStatus.RefreshInProgress | not) and
                ([.Instances[].ProtectedFromScaleIn] | all(. == false))
            )
        ) |
        sort_by(.AutoScalingGroupName) |
        .[].AutoScalingGroupName
    ' | tr '\n' ',' | sed 's/,$//'
}

# If no autoscaling names provided, list filtered Auto Scaling groups
if [[ -z "$AUTOSCALING_NAMES" ]]; then
    echo "Filtered Auto Scaling Groups:"
    FILTERED_GROUPS=$(list_autoscaling_groups 2>/dev/null || debug_list_autoscaling_groups)
    echo "${FILTERED_GROUPS}" # Output filtered list
    exit 0
fi

# Restart logic for each specified autoscaling group
IFS=',' read -r -a ASG_ARRAY <<< "$AUTOSCALING_NAMES"

for ASG_NAME in "${ASG_ARRAY[@]}"; do
    echo "Processing Auto Scaling Group: $ASG_NAME"

    # Check if the Auto Scaling group exists
    CURRENT_STATUS=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" $PROFILE \
        --auto-scaling-group-names "$ASG_NAME" \
        --query "AutoScalingGroups[0].AutoScalingGroupName" --output text)

    if [[ "$CURRENT_STATUS" == "None" ]]; then
        echo "Error: Auto Scaling Group $ASG_NAME not found." >&2
        exit 1
    fi

    # Skip matching groups if skip-matching is enabled
    if [[ "$SKIP_MATCHING" == "true" ]]; then
        SCALE_IN_PROTECTED=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" $PROFILE \
            --auto-scaling-group-names "$ASG_NAME" \
            --query "AutoScalingGroups[0].Instances[?ProtectedFromScaleIn==\`true\`].InstanceId" --output text)

        if [[ -n "$SCALE_IN_PROTECTED" ]]; then
            echo "Skipping $ASG_NAME due to scale-in protection on instances."
            continue
        fi
    fi

    # Restart Auto Scaling group by suspending and resuming processes
    echo "Suspending processes for $ASG_NAME..."
    aws autoscaling suspend-processes --region "$REGION" $PROFILE \
        --auto-scaling-group-name "$ASG_NAME"

    echo "Resuming processes for $ASG_NAME..."
    aws autoscaling resume-processes --region "$REGION" $PROFILE \
        --auto-scaling-group-name "$ASG_NAME"

    echo "Restarted Auto Scaling Group: $ASG_NAME"
done