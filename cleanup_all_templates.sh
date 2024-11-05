#!/bin/bash

set -eu

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
remote_clean_template_script="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/cleanup_template.sh"
remote_amis_cleanup_script="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/cleanup_amis_by_template.sh"

# Logging function
log() {
  local level="$1"
  local message="$2"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

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

# Find all launch templates
log "INFO" "Fetching launch templates from AWS..."
templates=$(aws ec2 describe-launch-templates --query "LaunchTemplates[].LaunchTemplateName" --output text --profile "$aws_profile" --region "$aws_region")

# Check if any templates are found
if [ -z "$templates" ]; then
  log "INFO" "No launch templates found."
  exit 0
else
  log "INFO" "Found launch templates: $templates"
fi

# Initialize an empty list to keep track of affected templates
affected_templates=()

# Iterate through each found template and clean it
for template_name in $templates; do
  log "INFO" "Starting cleanup for template: $template_name"

  # Run the clean_template script directly from the remote URL
  log "INFO" "Executing remote template cleanup for: $template_name"
  curl -s $remote_clean_template_script | bash -s -- -t "$template_name" -p "$aws_profile" ${aws_region:+-r "$aws_region"} -n "$num_versions_to_keep"
  
  if [ $? -eq 0 ]; then
    log "INFO" "Successfully cleaned template: $template_name"
    affected_templates+=("$template_name")
    
    # After successful template cleanup, run the remote cleanup_amis_by_template.sh script
    log "INFO" "Executing remote AMI cleanup for template: $template_name"
    curl -s $remote_amis_cleanup_script | bash -s -- --template "$template_name" --profile "$aws_profile" ${aws_region:+--region "$aws_region"}
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to execute AMI cleanup for template: $template_name"
    else
      log "INFO" "Successfully executed AMI cleanup for template: $template_name"
    fi
  else
    log "ERROR" "Failed to clean template: $template_name"
  fi
done

# Write the list of affected templates
if [ ${#affected_templates[@]} -gt 0 ]; then
  log "INFO" "Affected templates:"
  for template in "${affected_templates[@]}"; do
    log "INFO" " - $template"
  done
else
  log "INFO" "No templates were affected."
fi