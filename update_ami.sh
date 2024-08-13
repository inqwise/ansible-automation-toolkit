#!/bin/bash

# Function to display usage information
usage() {
    echo "Usage: $0 -t template_name -a new_ami_id -d version_description -p aws_profile -r aws_region"
    echo
    echo "Options:"
    echo "  -t  Specify the launch template name"
    echo "  -a  Specify the new AMI ID"
    echo "  -d  Specify the version description"
    echo "  -p  Specify the AWS profile"
    echo "  -r  Specify the AWS region"
    echo
    echo "Example:"
    echo "  $0 -t grafana -a ami-12345678 -d \"Updated AMI\" -p opinion-stg -r us-west-2"
    exit 1
}

# Default values
template_name=""
new_ami_id=""
version_description=""
aws_profile=""
aws_region=""

# Parse command-line arguments
while getopts "t:a:d:p:r:h" opt; do
  case $opt in
    t) template_name="$OPTARG" ;;
    a) new_ami_id="$OPTARG" ;;
    d) version_description="$OPTARG" ;;
    p) aws_profile="$OPTARG" ;;
    r) aws_region="$OPTARG" ;;
    h) usage ;;  # Display usage if -h is provided
    \?) echo "Invalid option -$OPTARG" >&2; usage ;;
  esac
done

# Validate required parameters
if [ -z "$template_name" ] || [ -z "$new_ami_id" ] || [ -z "$version_description" ] || [ -z "$aws_profile" ] || [ -z "$aws_region" ]; then
  echo "Error: Missing required arguments."
  usage
fi

# Retrieve the launch template ID using its name
template_info=$(aws ec2 describe-launch-templates \
  --query "LaunchTemplates[?LaunchTemplateName=='$template_name'].LaunchTemplateId" \
  --output text \
  --profile "$aws_profile" \
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
  --profile "$aws_profile" \
  --region "$aws_region")

# Extract the new version number from the response
version_number=$(echo "$version_info" | jq -r '.LaunchTemplateVersion.VersionNumber')

# Print the new version number
echo "New version created: $version_number"