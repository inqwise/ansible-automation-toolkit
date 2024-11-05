#!/bin/bash

set -eu

# Function to display usage information
usage() {
  echo "Usage: $0 -t template_names -r region -u user_data_file [-p profile] [-m]"
  echo "  -t  Comma-separated list of template names"
  echo "  -r  AWS region to use"
  echo "  -u  Path to the user data file"
  echo "  -p  AWS CLI profile to use (optional, default is to use the default profile)"
  echo "  -m  Make the last created version the default (optional)"
  exit 1
}

# Parse command-line arguments
make_default=false
while getopts ":t:r:u:p:m" opt; do
  case ${opt} in
    t )
      template_names=$OPTARG
      ;;
    r )
      region=$OPTARG
      ;;
    u )
      user_data_file=$OPTARG
      ;;
    p )
      profile=$OPTARG
      ;;
    m )
      make_default=true
      ;;
    \? )
      echo "Invalid option: $OPTARG" 1>&2
      usage
      ;;
    : )
      echo "Invalid option: $OPTARG requires an argument" 1>&2
      usage
      ;;
  esac
done
shift $((OPTIND -1))

# Check if all required arguments are provided
if [ -z "$template_names" ] || [ -z "$region" ] || [ -z "$user_data_file" ]; then
  usage
fi

# Encode the user data file
USER_DATA_ENCODED=$(base64 < "$user_data_file")

# Split the template_names string into an array
IFS=',' read -r -a template_array <<< "$template_names"

# Loop through each template name
for template_name in "${template_array[@]}"; do
  # Retrieve the launch template ID using its name
  if [ -n "$profile" ]; then
    template_id=$(aws ec2 describe-launch-templates --region "$region" --query "LaunchTemplates[?LaunchTemplateName=='$template_name'].LaunchTemplateId" --output text --profile "$profile")
  else
    template_id=$(aws ec2 describe-launch-templates --region "$region" --query "LaunchTemplates[?LaunchTemplateName=='$template_name'].LaunchTemplateId" --output text)
  fi

  # Check if the template exists
  if [ -z "$template_id" ]; then
    echo "Launch template with name $template_name not found. Skipping."
  else
    echo "Launch template with name $template_name found. Creating a new version."
    
    # Prepare the launch template data
    launch_template_data="{\"UserData\":\"$USER_DATA_ENCODED\"}"
    
    # Create a new version of the launch template
    if [ -n "$profile" ]; then
      version_info=$(aws ec2 create-launch-template-version --region "$region" --launch-template-id "$template_id" --source-version '$Latest' --launch-template-data "$launch_template_data" --profile "$profile")
    else
      version_info=$(aws ec2 create-launch-template-version --region "$region" --launch-template-id "$template_id" --source-version '$Latest' --launch-template-data "$launch_template_data")
    fi
    
    # Extract the new version number from the response
    version_number=$(echo "$version_info" | jq -r '.LaunchTemplateVersion.VersionNumber')
    
    # Print the new version number
    echo "New version created: $version_number for Launch template $template_name."
    
    # Make the new version the default if the -m flag was provided
    if [ "$make_default" = true ]; then
      if [ -n "$profile" ]; then
        aws ec2 modify-launch-template --region "$region" --launch-template-id "$template_id" --default-version "$version_number" --profile "$profile"
      else
        aws ec2 modify-launch-template --region "$region" --launch-template-id "$template_id" --default-version "$version_number"
      fi
      echo "Version $version_number is now the default version for Launch template $template_name."
    fi
  fi
done