#!/bin/bash

# Define variables
template_name="grafana"
num_versions_to_keep=3
# Get the $Default version of the launch template
default_version=$(aws ec2 describe-launch-templates --query "LaunchTemplates[?LaunchTemplateName=='$template_name'].DefaultVersionNumber" --output text --profile opinion-stg)

# Check if the template exists
if [ -z "$default_version" ]; then
  echo "Launch template with name $template_name not found."
  exit 1
fi

template_id=$(aws ec2 describe-launch-templates --query "LaunchTemplates[?LaunchTemplateName=='$template_name'].LaunchTemplateId" --output text --profile opinion-stg)

# Get all versions of the launch template
all_versions=$(aws ec2 describe-launch-template-versions --launch-template-name "$template_name" --output json --profile opinion-stg)

# Parse the versions and delete the older ones
echo "$all_versions" | jq -r --arg default "$default_version" '.LaunchTemplateVersions[] | select(.VersionNumber != $default) | .VersionNumber' | sort -nr | tail -n +$((num_versions_to_keep+1)) | while read -r version_number; do
  echo "Deleting version $version_number of launch template $template_name..."
  aws ec2 delete-launch-template-versions --launch-template-id "$template_id" --versions "$version_number" --profile opinion-stg
done
