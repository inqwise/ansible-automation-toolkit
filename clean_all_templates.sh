#!/bin/bash

# Usage information
usage() {
  echo "Usage: $0 -p aws_profile [-r aws_region] [-n num_versions_to_keep]"
  echo "  -p  Specify the AWS profile (required)"
  echo "  -r  Specify the AWS region"
  echo "  -n  Specify the number of versions to keep (default: 3)"
  exit 1
}

# Default values
aws_region=""
num_versions_to_keep=3
remote_script_url="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/clean_template.sh"
local_script="clean_template.sh"

# Parse command-line arguments
while getopts ":p:r:n:" opt; do
  case ${opt} in
    p)
      aws_profile="$OPTARG"
      ;;
    r)
      aws_region="$OPTARG"
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
if [ -z "$aws_profile" ]; then
  usage
fi

# Check if the clean_template.sh script exists locally, if not download it
if [ ! -f "$local_script" ]; then
  echo "Local clean_template.sh not found. Downloading from remote URL..."
  curl -O "$remote_script_url"
  if [ $? -ne 0 ]; then
    echo "Failed to download clean_template.sh from $remote_script_url"
    exit 1
  fi
  chmod +x "$local_script"
fi

# Find all launch templates
templates=$(aws ec2 describe-launch-templates --query "LaunchTemplates[].LaunchTemplateName" --output text --profile "$aws_profile" --region "$aws_region")

# Check if any templates are found
if [ -z "$templates" ]; then
  echo "No launch templates found."
  exit 0
fi

# Initialize an empty list to keep track of affected templates
affected_templates=()

# Iterate through each found template and clean it
for template_name in $templates; do
  echo "Cleaning template: $template_name"
  ./$local_script -t "$template_name" -p "$aws_profile" ${aws_region:+-r "$aws_region"} -n "$num_versions_to_keep"
  if [ $? -eq 0 ]; then
    affected_templates+=("$template_name")
  fi
done

# Write the list of affected templates
if [ ${#affected_templates[@]} -gt 0 ]; then
  echo "Affected templates:"
  for template in "${affected_templates[@]}"; do
    echo "$template"
  done
else
  echo "No templates were affected."
fi