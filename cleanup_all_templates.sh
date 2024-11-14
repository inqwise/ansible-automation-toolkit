#!/bin/bash

set -eu

# Usage information
usage() {
  cat <<EOF
Usage: $0 --profile <aws_profile> [--region <aws_region>] [--keep-history <num>] [--dry-run]
       $0 -p <aws_profile> [-r <aws_region>] [-k <num>] [-d]

Options:
  -p, --profile               Specify the AWS profile (optional)
  -r, --region                Specify the AWS region
  -k, --keep-history          Specify the number of versions to keep (default: 3)
  -d, --dry-run               Enable dry-run mode (simulate actions without making changes)
  -h, --help                  Display this help message and exit
EOF
  exit 1
}

# Default values
aws_region=""
keep_history=3
dry_run=false

# Remote script URLs
remote_clean_template_script="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/cleanup_template.sh"
remote_amis_cleanup_script="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/cleanup_amis_by_template.sh"

# Determine the directory where the main script resides
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Directory to store downloaded scripts
scripts_dir="$script_dir/scripts"

# Local paths for the downloaded scripts
local_clean_template_script="$scripts_dir/cleanup_template.sh"
local_amis_cleanup_script="$scripts_dir/cleanup_amis_by_template.sh"

# Logging function
log() {
  local level="$1"
  local message="$2"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

# Function to download a script if it doesn't exist locally
download_script() {
  local url="$1"
  local destination="$2"
  local script_name
  script_name=$(basename "$destination")

  if [ -f "$destination" ]; then
    log "INFO" "Script '$script_name' already exists locally. Skipping download."
  else
    log "INFO" "Downloading '$script_name' from $url..."
    curl -sSL "$url" -o "$destination"
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to download '$script_name' from $url."
      exit 1
    fi
    chmod +x "$destination"
    log "INFO" "Successfully downloaded and set execute permissions for '$script_name'."
  fi
}

# Function to parse command-line arguments using getopt
parse_args() {
  # Use getopt to parse both short and long options
  PARSED_OPTIONS=$(getopt -n "$0" -o p:r:k:dh --long profile:,region:,keep-history:,dry-run,help -- "$@")
  if [ $? -ne 0 ]; then
    usage
  fi

  eval set -- "$PARSED_OPTIONS"

  while true; do
    case "$1" in
      -p|--profile)
        aws_profile="$2"
        shift 2
        ;;
      -r|--region)
        aws_region="$2"
        shift 2
        ;;
      -k|--keep-history)
        keep_history="$2"
        shift 2
        ;;
      -d|--dry-run)
        dry_run=true
        shift
        ;;
      -h|--help)
        usage
        ;;
      --)
        shift
        break
        ;;
      *)
        echo "Unknown option: $1"
        usage
        ;;
    esac
  done

  # Export aws_profile to use it outside the function if it's set
  if [ -n "${aws_profile:-}" ]; then
    export aws_profile
  fi
}

# Parse command-line arguments
parse_args "$@"

# Check for required arguments (if any)
# Since profile is optional, no need to check for its presence

# Validate --keep-history is a positive integer
if ! [[ "$keep_history" =~ ^[1-9][0-9]*$ ]]; then
  log "ERROR" "--keep-history must be a positive integer."
  exit 1
fi

# Create scripts directory if it doesn't exist
if [ ! -d "$scripts_dir" ]; then
  mkdir -p "$scripts_dir"
  log "INFO" "Created scripts directory at '$scripts_dir'."
fi

# Download remote scripts if they don't exist locally
download_script "$remote_clean_template_script" "$local_clean_template_script"
download_script "$remote_amis_cleanup_script" "$local_amis_cleanup_script"

# Function to build AWS CLI arguments
build_aws_args() {
  local args=()
  if [ -n "${aws_profile:-}" ]; then
    args+=("--profile" "$aws_profile")
  fi
  if [ -n "$aws_region" ]; then
    args+=("--region" "$aws_region")
  fi
  echo "${args[@]}"
}

# Function to build cleanup_template.sh arguments
build_cleanup_template_args() {
  local template_name="$1"
  local args=("-t" "$template_name")
  if [ -n "${aws_profile:-}" ]; then
    args+=("-p" "$aws_profile")
  fi
  if [ -n "$aws_region" ]; then
    args+=("-r" "$aws_region")
  fi
  args+=("-n" "$keep_history")
  echo "${args[@]}"
}

# Function to build cleanup_amis_by_template.sh arguments
build_cleanup_amis_args() {
  local template_name="$1"
  local args=("--template" "$template_name")
  if [ -n "${aws_profile:-}" ]; then
    args+=("--profile" "$aws_profile")
  fi
  if [ -n "$aws_region" ]; then
    args+=("--region" "$aws_region")
  fi

  if [ -n "${keep_history:-}" ]; then
    args+=("--keep-history" "$keep_history")
  fi

  if [ "$dry_run" = true ]; then
    args+=("--dry-run")
  fi

  echo "${args[@]}"
}

# Function to check if a template has the tag 'amm:SkipClean' set to 'true'
should_skip_template() {
  local template_name="$1"
  # Fetch tags for the specific launch template
  tags=$(aws ec2 describe-launch-templates --launch-template-names "$template_name" \
    --query "LaunchTemplates[].Tags[?Key=='amm:SkipClean'].Value[]" --output text $(build_aws_args))
  
  # Check if the tag value is 'true' (case-insensitive)
  if [[ "$tags" =~ ^[Tt][Rr][Uu][Ee]$ ]]; then
    return 0  # Should skip
  else
    return 1  # Should not skip
  fi
}

# Find all launch templates
log "INFO" "Fetching launch templates from AWS..."
# Build AWS CLI arguments
aws_args=$(build_aws_args)
templates=$(aws ec2 describe-launch-templates --query "LaunchTemplates[].LaunchTemplateName" --output text $aws_args)
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

  # Check if the template has the 'amm:SkipClean' tag set to 'true'
  if should_skip_template "$template_name"; then
    log "INFO" "Template '$template_name' has tag 'amm:SkipClean=true'. Skipping cleanup."
    continue  # Skip to the next template
  fi

  if [ "$dry_run" = true ]; then
    # Simulate template cleanup
    log "DRY-RUN" "Would execute: $local_clean_template_script $(build_cleanup_template_args "$template_name")"
    log "INFO" "Dry-run: Simulated cleaning template: $template_name"
    affected_templates+=("$template_name")
  else
    # Execute the cleanup template script
    log "INFO" "Executing local template cleanup for: $template_name"
    "$local_clean_template_script" $(build_cleanup_template_args "$template_name")

    if [ $? -eq 0 ]; then
      log "INFO" "Successfully cleaned template: $template_name"
      affected_templates+=("$template_name")
    else
      log "ERROR" "Failed to clean template: $template_name"
      continue
    fi
  fi

  # Prepare and execute the AMI cleanup command
  if [ "$dry_run" = true ]; then
    # Execute AMI cleanup script in dry-run mode
    log "INFO" "Executing local AMI cleanup for template: $template_name with --dry-run"
    "$local_amis_cleanup_script" $(build_cleanup_amis_args "$template_name")
    log "INFO" "Dry-run: Simulated AMI cleanup for template: $template_name"
  else
    # Execute AMI cleanup script normally
    log "INFO" "Executing local AMI cleanup for template: $template_name"
    "$local_amis_cleanup_script" $(build_cleanup_amis_args "$template_name")

    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to execute AMI cleanup for template: $template_name"
    else
      log "INFO" "Successfully executed AMI cleanup for template: $template_name"
    fi
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

# Exit successfully
exit 0