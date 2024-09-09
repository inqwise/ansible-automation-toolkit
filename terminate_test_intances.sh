#!/bin/bash
set -euo pipefail

# Function to display usage instructions
usage() {
  echo "Usage: $0 --region <AWS_REGION> [--profile <AWS_PROFILE>]"
  exit 1
}

# Function to terminate EC2 instances containing '-test' in their Name tag
terminate_test_instances() {
  local region=$1
  local profile=${2:-}

  echo "Using region: $region"

  # Fetch instances with or without a specified profile
  if [ -n "$profile" ]; then
    echo "Using profile: $profile"
    instance_ids=$(aws ec2 describe-instances \
      --profile "$profile" \
      --region "$region" \
      --filters "Name=tag:Name,Values=*-test*" \
      --query "Reservations[].Instances[?State.Name == 'running'].InstanceId" \
      --output text)
  else
    echo "Using default profile"
    instance_ids=$(aws ec2 describe-instances \
      --region "$region" \
      --filters "Name=tag:Name,Values=*-test*" \
      --query "Reservations[].Instances[?State.Name == 'running'].InstanceId" \
      --output text)
  fi

  if [ -z "$instance_ids" ]; then
    echo "No running instances found with '-test' in their name."
    exit 0
  fi

  echo "Found the following instances with '-test' in their name:"
  echo "$instance_ids"

  # Add a description to the instances (this actually adds a tag for description)
  for instance_id in $instance_ids; do
    echo "Adding description tag to instance $instance_id"
    if [ -n "$profile" ]; then
      aws ec2 create-tags \
        --profile "$profile" \
        --region "$region" \
        --resources "$instance_id" \
        --tags Key=Description,Value="Terminated by automated script for test instances"
    else
      aws ec2 create-tags \
        --region "$region" \
        --resources "$instance_id" \
        --tags Key=Description,Value="Terminated by automated script for test instances"
    fi
  done

  # Terminate instances
  echo "Terminating instances..."
  if [ -n "$profile" ]; then
    aws ec2 terminate-instances --profile "$profile" --region "$region" --instance-ids $instance_ids
  else
    aws ec2 terminate-instances --region "$region" --instance-ids $instance_ids
  fi

  echo "Termination initiated for the following instances:"
  echo "$instance_ids"
}

# Ensure that AWS_REGION is passed as an argument
if [ "$#" -lt 2 ]; then
  usage
fi

# Initialize variables
AWS_PROFILE=""
AWS_REGION=""

# Parse the arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --profile)
      AWS_PROFILE="$2"
      shift
      ;;
    --region)
      AWS_REGION="$2"
      shift
      ;;
    *)
      echo "Unknown parameter passed: $1"
      usage
      ;;
  esac
  shift
done

# Validate that the region is provided
if [ -z "$AWS_REGION" ]; then
  usage
fi

# Execute the termination function
terminate_test_instances "$AWS_REGION" "$AWS_PROFILE"