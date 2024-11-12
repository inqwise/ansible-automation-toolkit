#!/bin/bash

set -eu

# Usage information
usage() {
  echo "Usage: $0 -t template_name [-p aws_profile] [-r aws_region] [-n num_versions_to_keep]"
  echo "  -t  Specify the launch template name (required)"
  echo "  -p  Specify the AWS profile (optional)"
  echo "  -r  Specify the AWS region"
  echo "  -n  Specify the number of versions to keep (default: 3)"
  exit 1
}

# Default values
aws_profile=""
aws_region=""
num_versions_to_keep=3

# Parse command-line arguments
while getopts ":t:p:r:n:" opt; do
  case ${opt} in
    t)
      template_name="$OPTARG"
      ;;
    p)
      aws_profile="$OPTARG"
      ;;
    r)
      aws_region="--region $OPTARG"
      ;;
    n)
      num_versions_to_keep="$OPTARG"
      ;;
    *)
      usage
      ;;
  esac
done

# Check for required arguments
if [ -z "${template_name:-}" ]; then
  usage
fi

# Function to construct AWS CLI options
aws_options() {
  local options=""
  if [ -n "$aws_profile" ]; then
    options+=" --profile \"$aws_profile\""
  fi
  if [ -n "$aws_region" ]; then
    options+=" $aws_region"
  fi
  echo "$options"
}

# Construct AWS CLI options
AWS_OPTS=$(aws_options)

# Get the $Default version of the launch template
default_version=$(eval "aws ec2 describe-launch-templates --query \"LaunchTemplates[?LaunchTemplateName=='$template_name'].DefaultVersionNumber\" --output text $AWS_OPTS")

# Check if the template exists
if [ -z "$default_version" ]; then
  echo "Launch template with name $template_name not found."
  exit 1
fi

template_id=$(eval "aws ec2 describe-launch-templates --query \"LaunchTemplates[?LaunchTemplateName=='$template_name'].LaunchTemplateId\" --output text $AWS_OPTS")

# Get all versions of the launch template
all_versions=$(eval "aws ec2 describe-launch-template-versions --launch-template-name \"$template_name\" --output json $AWS_OPTS")

# Parse the versions and delete the older ones
echo "$all_versions" | jq -r --arg default "$default_version" '.LaunchTemplateVersions[] | select(.VersionNumber != ($default | tonumber)) | .VersionNumber' | sort -nr | tail -n +$((num_versions_to_keep + 1)) | while read -r version_number; do
  echo "Deleting version $version_number of launch template $template_name..."
  eval "aws ec2 delete-launch-template-versions --launch-template-id \"$template_id\" --versions \"$version_number\" $AWS_OPTS"
done