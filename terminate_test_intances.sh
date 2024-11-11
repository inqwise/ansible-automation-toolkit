#!/bin/bash
set -euo pipefail

# Function to display usage instructions
usage() {
  echo "Usage: $0 --region <AWS_REGION> [--profile <AWS_PROFILE>] [--dry-run]"
  exit 1
}

# Function to terminate EC2 instances containing '-test' in their Name tag
terminate_test_instances() {
  local region=$1
  local profile=$2
  local dry_run=$3

  echo "Using region: $region"

  # Construct AWS CLI base options
  AWS_CLI_OPTS=("--region" "$region")
  if [ -n "$profile" ]; then
    AWS_CLI_OPTS+=("--profile" "$profile")
    echo "Using profile: $profile"
  else
    echo "Using default profile"
  fi

  # Fetch running instances with '-test' in their Name tag
  instance_ids=$(aws ec2 describe-instances \
    "${AWS_CLI_OPTS[@]}" \
    --filters "Name=tag:Name,Values=*-test*" \
    --query "Reservations[].Instances[?State.Name == 'running'].InstanceId" \
    --output text)

  if [ -z "$instance_ids" ]; then
    echo "No running instances found with '-test' in their name."
    exit 0
  fi

  echo "Found the following instances with '-test' in their name:"
  echo "$instance_ids"

  # Add a description tag to the instances
  for instance_id in $instance_ids; do
    echo "Adding description tag to instance $instance_id"
    aws ec2 create-tags \
      "${AWS_CLI_OPTS[@]}" \
      --resources "$instance_id" \
      --tags Key=Description,Value="Terminated by automated script for test instances" \
      ${dry_run:+--dry-run}
  done

  # Terminate instances
  echo "Terminating instances..."
  aws ec2 terminate-instances \
    "${AWS_CLI_OPTS[@]}" \
    --instance-ids $instance_ids \
    ${dry_run:+--dry-run}

  echo "Termination initiated for the following instances:"
  echo "$instance_ids"
}

# Ensure that at least the region is passed as an argument
if [ "$#" -lt 2 ]; then
  usage
fi

# Initialize variables
AWS_PROFILE=""
AWS_REGION=""
DRY_RUN=false

# Parse the arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --profile)
      if [[ -n "${2:-}" && ! "$2" =~ ^-- ]]; then
        AWS_PROFILE="$2"
        shift
      else
        echo "Error: --profile requires a value."
        usage
      fi
      ;;
    --region)
      if [[ -n "${2:-}" && ! "$2" =~ ^-- ]]; then
        AWS_REGION="$2"
        shift
      else
        echo "Error: --region requires a value."
        usage
      fi
      ;;
    --dry-run)
      DRY_RUN=true
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
  echo "Error: --region is required."
  usage
fi

# Inform the user if dry-run is enabled
if [ "$DRY_RUN" = true ]; then
  echo "Dry run mode enabled. No changes will be made."
fi

# Execute the termination function
terminate_test_instances "$AWS_REGION" "$AWS_PROFILE" "$DRY_RUN"