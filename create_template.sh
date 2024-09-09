#!/bin/bash

# Enable strict error handling
set -euo pipefail

# Function to display usage help
usage() {
    echo "Usage: $0 --template-name <TEMPLATE_NAME> --region <REGION> [--profile <PROFILE>]"
    echo ""
    echo "Mandatory Arguments:"
    echo "  --template-name   Name of the launch template (e.g., 'mysql')"
    echo "  --region          AWS region (e.g., 'us-east-1')"
    echo ""
    echo "Optional Arguments:"
    echo "  --profile         AWS CLI profile (default: 'default')"
    echo ""
    exit 1
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --template-name) TEMPLATE_NAME="$2"; shift ;;
        --region) REGION="$2"; shift ;;
        --profile) PROFILE="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Validation for mandatory fields
if [[ -z "${TEMPLATE_NAME:-}" || -z "${REGION:-}" ]]; then
    echo "Error: --template-name and --region are mandatory."
    usage
fi

# Set default profile if not provided
PROFILE="${PROFILE:-default}"

# Set other variables
USER_DATA_URL="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/userdata.sh"  # User data file URL
USER_DATA_FILE="userdata.sh"
IAM_INSTANCE_PROFILE_NAME="bootstrap-role"  # IAM instance profile

# Download the user data file from the URL
echo "Downloading user data file from $USER_DATA_URL"
curl -s -o "$USER_DATA_FILE" "$USER_DATA_URL"

# Check if user data file was downloaded and is not empty
if [[ ! -s "$USER_DATA_FILE" ]]; then
  echo "Failed to download or empty user data file."
  exit 1
fi

# Search for the latest AMI based on the template name
AMI_DATA=$(aws ec2 describe-images \
  --filters "Name=name,Values=${TEMPLATE_NAME}-*" \
            "Name=state,Values=available" \
  --query "Images | sort_by(@, &CreationDate)[-1]" \
  --output json --profile "$PROFILE" --region "$REGION")

AMI_ID=$(echo "$AMI_DATA" | jq -r '.ImageId')
AMI_DESCRIPTION=$(echo "$AMI_DATA" | jq -r '.Description')

if [[ "$AMI_ID" == "None" || -z "$AMI_ID" ]]; then
  echo "AMI not found for template name: $TEMPLATE_NAME"
  exit 1
fi

# Print the found AMI description
echo "Found AMI ID: $AMI_ID"
echo "AMI Description: $AMI_DESCRIPTION"

# Find the key pair ending with '-bootstrap'
KEY_PAIR=$(aws ec2 describe-key-pairs \
  --filters "Name=key-name,Values=*bootstrap" \
  --query "KeyPairs[0].KeyName" --output text \
  --profile "$PROFILE" --region "$REGION")

if [[ "$KEY_PAIR" == "None" || -z "$KEY_PAIR" ]]; then
  echo "No key pair found ending with '-bootstrap'."
  exit 1
fi

# Find the security group with the name of the template
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${TEMPLATE_NAME}" \
  --query "SecurityGroups[0].GroupId" --output text \
  --profile "$PROFILE" --region "$REGION")

if [[ "$SECURITY_GROUP_ID" == "None" || -z "$SECURITY_GROUP_ID" ]]; then
  echo "Security group not found with name: $TEMPLATE_NAME"
  exit 1
fi

# Find IAM instance profile with the name 'bootstrap-role'
IAM_INSTANCE_PROFILE_ARN=$(aws iam get-instance-profile \
  --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" \
  --query "InstanceProfile.Arn" --output text \
  --profile "$PROFILE")

if [[ "$IAM_INSTANCE_PROFILE_ARN" == "None" || -z "$IAM_INSTANCE_PROFILE_ARN" ]]; then
  echo "IAM instance profile 'bootstrap-role' not found."
  exit 1
fi

# Check if the launch template already exists
EXISTING_TEMPLATE=$(aws ec2 describe-launch-templates \
  --filters "Name=launch-template-name,Values=${TEMPLATE_NAME}" \
  --query "LaunchTemplates[0].LaunchTemplateId" --output text \
  --profile "$PROFILE" --region "$REGION")

# If the template doesn't exist, create it
if [[ "$EXISTING_TEMPLATE" == "None" || -z "$EXISTING_TEMPLATE" ]]; then
  echo "Creating launch template: $TEMPLATE_NAME with AMI: $AMI_ID"

  # Attempt to encode the user data file to base64
  if base64 "$USER_DATA_FILE" >/dev/null 2>&1; then
    USER_DATA_BASE64=$(base64 "$USER_DATA_FILE" | tr -d '\n')
  else
    echo "Failed to encode user data file to base64. Trying alternative method..."
    
    # Alternative base64 encoding method using openssl (if base64 fails)
    if command -v openssl >/dev/null 2>&1; then
      USER_DATA_BASE64=$(openssl base64 -in "$USER_DATA_FILE" | tr -d '\n')
    else
      echo "No working base64 or openssl found to encode the file."
      exit 1
    fi
  fi

  aws ec2 create-launch-template \
    --launch-template-name "$TEMPLATE_NAME" \
    --version-description "Launch template for $TEMPLATE_NAME (Auto Scaling)" \
    --launch-template-data "{
      \"ImageId\": \"$AMI_ID\",
      \"KeyName\": \"$KEY_PAIR\",
      \"SecurityGroupIds\": [\"$SECURITY_GROUP_ID\"],
      \"UserData\": \"$USER_DATA_BASE64\",
      \"IamInstanceProfile\": { \"Arn\": \"$IAM_INSTANCE_PROFILE_ARN\" },
      \"MetadataOptions\": {
        \"HttpTokens\": \"required\",
        \"HttpPutResponseHopLimit\": 2,
        \"InstanceMetadataTags\": \"enabled\"
      },
      \"TagSpecifications\": [
        {
          \"ResourceType\": \"instance\",
          \"Tags\": [
            { \"Key\": \"playbook_name\", \"Value\": \"$TEMPLATE_NAME\" }
          ]
        }
      ]
    }" --profile "$PROFILE" --region "$REGION"

  if [[ $? -eq 0 ]]; then
    echo "Launch template $TEMPLATE_NAME created successfully."
  else
    echo "Failed to create launch template."
    exit 1
  fi
else
  echo "Launch template $TEMPLATE_NAME already exists."
fi