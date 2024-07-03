#!/bin/bash

# Define variables
template_name="grafana"
user_data_file="userdata.sh"

# Retrieve the launch template ID using its name
template_info=$(aws ec2 describe-launch-templates --query "LaunchTemplates[?LaunchTemplateName=='$template_name'].LaunchTemplateId" --output text --profile opinion-stg)

# Check if the template exists
if [ -z "$template_info" ]; then
  echo "Launch template with name $template_name not found."
  exit 1
fi

# Create a new version of the launch template
ENCODED_CONTENT=$(sed "s/{{ vault_password }}/$(op read 'op://Security/ansible-vault inqwise-stg/password')/g" "$user_data_file" | base64)
version_info=$(aws ec2 create-launch-template-version --launch-template-id "$template_info" --source-version '$Latest' --launch-template-data "{\"UserData\":\"$ENCODED_CONTENT\"}" --profile opinion-stg)
#version_info=$(aws ec2 create-launch-template-version --launch-template-id "$template_info" --source-version '$Latest' --launch-template-data "{\"UserData\":\"$(base64 < "$user_data_file")\"}" --profile opinion-stg)
#aws ec2 create-launch-template-version --launch-template-id lt-0f7084ee6a51b1dd0 --version-description 'update user data' --source-version '$Latest' --launch-template-data "UserData"=$USER_DATA"

# Extract the new version number from the response
version_number=$(echo "$version_info" | jq -r '.LaunchTemplateVersion.VersionNumber')

# Print the new version number
echo "New version created: $version_number"