#!/bin/bash

set -eu

# Function to display usage information
usage() {
    echo "Usage: $0 -t template_name -a new_ami_id -d version_description -r aws_region [-p aws_profile] [-m]"
    echo
    echo "Options:"
    echo "  -t  Specify the launch template name"
    echo "  -a  Specify the new AMI ID"
    echo "  -d  Specify the version description"
    echo "  -r  Specify the AWS region"
    echo "  -p  (Optional) Specify the AWS profile"
    echo "  -m  (Optional) If provided, set the new version as the default"
    echo
    echo "Example:"
    echo "  $0 -t grafana -a ami-12345678 -d \"Updated AMI\" -r us-west-2 -p opinion-stg -m"
    exit 1
}

# Default values
template_name=""
new_ami_id=""
version_description=""
aws_profile=""
aws_region=""
make_default=false  # Flag to determine if the new version should be set as default

# Parse command-line arguments
while getopts "t:a:d:p:r:mh" opt; do
  case $opt in
    t) template_name="$OPTARG" ;;
    a) new_ami_id="$OPTARG" ;;
    d) version_description="$OPTARG" ;;
    p) aws_profile="$OPTARG" ;;
    r) aws_region="$OPTARG" ;;
    m) make_default=true ;;  # Set the flag if -m is provided
    h) usage ;;  # Display usage if -h is provided
    \?) echo "Invalid option -$OPTARG" >&2; usage ;;
  esac
done

# Validate required parameters
if [ -z "$template_name" ] || [ -z "$new_ami_id" ] || [ -z "$version_description" ] || [ -z "$aws_region" ]; then
  echo "Error: Missing required arguments."
  usage
fi

# Build AWS CLI profile option
profile_option=""
if [ -n "$aws_profile" ]; then
  profile_option="--profile $aws_profile"
fi

# Retrieve the launch template ID using its name
template_info=$(aws ec2 describe-launch-templates \
  --query "LaunchTemplates[?LaunchTemplateName=='$template_name'].LaunchTemplateId" \
  --output text \
  $profile_option \
  --region "$aws_region")

# Check if the template exists
if [ -z "$template_info" ]; then
  echo "Launch template with name $template_name not found."
  exit 1
fi

# Create a new version of the launch template with the updated AMI ID
version_info=$(aws ec2 create-launch-template-version \
  --launch-template-id "$template_info" \
  --source-version '$Latest' \
  --launch-template-data "{\"ImageId\":\"$new_ami_id\"}" \
  --version-description "$version_description" \
  $profile_option \
  --region "$aws_region")

# Extract the new version number from the response
version_number=$(echo "$version_info" | jq -r '.LaunchTemplateVersion.VersionNumber')

# Print the new version number
echo "New version created: $version_number"

# If the -m option was provided, set the new version as the default
if $make_default; then
  aws ec2 modify-launch-template \
    --launch-template-id "$template_info" \
    --default-version "$version_number" \
    $profile_option \
    --region "$aws_region"
  echo "Version $version_number set as the default version."
fi