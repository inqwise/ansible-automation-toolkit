#!/bin/bash

set -eu

# Usage information
usage() {
  cat <<EOF
Usage: $0 --region <aws_region> [--profile <aws_profile>] [--keep-history <num>] [--dry-run] [--clean-scope <scope>]

Options:
  --region                Specify the AWS region (mandatory)
  --profile               Specify the AWS profile (optional)
  --keep-history          Specify the number of versions to keep (default: 3)
  --dry-run               Enable dry-run mode (simulate actions without making changes)
  --clean-scope           Define clean scope ('all' or 'none', default: 'all')
  --help                  Display this help message and exit
EOF
  exit 1
}

# Default values
aws_region=""
keep_history=3
dry_run=false
clean_scope="all"

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

# Function to parse command-line arguments (long options only)
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --region)
        aws_region="$2"
        shift 2
        ;;
      --profile)
        aws_profile="$2"
        shift 2
        ;;
      --keep-history)
        keep_history="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      --clean-scope)
        clean_scope="$2"
        if [[ ! "$clean_scope" =~ ^(all|none)$ ]]; then
          log "ERROR" "--clean-scope must be 'all' or 'none'."
          exit 1
        fi
        shift 2
        ;;
      --help)
        usage
        ;;
      *)
        log "ERROR" "Unknown option: $1"
        usage
        ;;
    esac
  done

  # Since region is mandatory, check if it's provided
  if [ -z "$aws_region" ]; then
    log "ERROR" "Mandatory argument --region is missing."
    usage
  fi

  # Export aws_profile to use it outside the function if it's set
  if [ -n "${aws_profile:-}" ]; then
    export aws_profile
  fi
}

# Parse command-line arguments
parse_args "$@"

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

# Function to determine if a template should be processed based on the clean scope
should_process_template() {
  local template_name="$1"

  case "$clean_scope" in
    all)
      # In 'all' scope, process all except those with amm:SkipClean=true
      tags=$(aws ec2 describe-launch-templates --launch-template-names "$template_name" \
        --query "LaunchTemplates[].Tags[?Key=='amm:SkipClean'].Value[]" --output text $(build_aws_args) || true)
      if [[ "$tags" =~ ^[Tt][Rr][Uu][Ee]$ ]]; then
        return 1 # skip this template
      else
        return 0 # process this template
      fi
      ;;
    none)
      # In 'none' scope, process only those with amm:Clean=true
      tags=$(aws ec2 describe-launch-templates --launch-template-names "$template_name" \
        --query "LaunchTemplates[].Tags[?Key=='amm:Clean'].Value[]" --output text $(build_aws_args) || true)
      if [[ "$tags" =~ ^[Tt][Rr][Uu][Ee]$ ]]; then
        return 0 # process this template
      else
        return 1 # skip this template
      fi
      ;;
  esac
}

log "INFO" "Fetching launch templates from AWS..."
aws_args=$(build_aws_args)
templates=$(aws ec2 describe-launch-templates --query "LaunchTemplates[].LaunchTemplateName" --output text $aws_args || true)
if [ -z "$templates" ]; then
  log "INFO" "No launch templates found."
  exit 0
else
  log "INFO" "Found launch templates: $templates"
fi

affected_templates=()

for template_name in $templates; do
  log "INFO" "Starting cleanup for template: $template_name"

  if ! should_process_template "$template_name"; then
    log "INFO" "Template '$template_name' does not meet criteria for clean-scope='$clean_scope'. Skipping."
    continue
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
    log "INFO" "Executing local AMI cleanup for template: $template_name with --dry-run"
    "$local_amis_cleanup_script" $(build_cleanup_amis_args "$template_name")
    log "INFO" "Dry-run: Simulated AMI cleanup for template: $template_name"
  else
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

exit 0