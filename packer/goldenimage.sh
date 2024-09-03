#!/usr/bin/env bash
# Constants
LOCAL_IDENTIFY_OS_SCRIPT="identify_os.sh"
TOOLKIT_VERSION="${TOOLKIT_VERSION:-default}"
VAULT_PASSWORD_FILE="vault_password"
PIP_COMMAND="${PIP_COMMAND:-pip}"

GET_PIP_URL="${GET_PIP_URL:-https://bootstrap.pypa.io/get-pip.py}"
PLAYBOOK_VERSION="${PLAYBOOK_VERSION:-latest}"
REGION="${REGION:-}"
PLAYBOOK_NAME="${PLAYBOOK_NAME:-}"
PLAYBOOK_BASE_URL="${PLAYBOOK_BASE_URL:-}"
VAULT_PASSWORD="${VAULT_PASSWORD:-}"
VERBOSE="${VERBOSE:-false}"

usage() {
    echo "Usage: $0 -r <region> --playbook_name <name> --playbook_base_url <url> --vault_password <password> [options]"
    echo
    echo "Mandatory arguments:"
    echo "  -r <region>                   Specify the region."
    echo "  --playbook_name <name>        Specify the playbook name."
    echo "  --playbook_base_url <url>     Specify the base URL for the playbook."
    echo "  --vault_password <password>   Specify the vault password."
    echo
    echo "Optional arguments:"
    echo "  --token <token>               Specify the token."
    echo "  --get_pip_url <url>           Specify the URL for get-pip."
    echo "  --account_id <id>             Specify the account ID."
    echo "  --topic_name <name>           Specify the topic name."
    echo "  --playbook_version <version>  Specify the playbook version."
    echo "  --toolkit_version <version>   Specify the toolkit version."
    echo "  --verbose                     Enable verbose mode."
    exit 1
}

while getopts ":r:-:" option; do
  case "${option}" in
    r)
      REGION=${OPTARG}
      ;;
    -)
      case "${OPTARG}" in
        get_pip_url)
          GET_PIP_URL="${!OPTIND}"; OPTIND=$((OPTIND + 1))
          ;;
        playbook_name)
          PLAYBOOK_NAME="${!OPTIND}"; OPTIND=$((OPTIND + 1))
          ;;
        playbook_base_url)
          PLAYBOOK_BASE_URL="${!OPTIND}"; OPTIND=$((OPTIND + 1))
          ;;
        vault_password)
          VAULT_PASSWORD="${!OPTIND}"; OPTIND=$((OPTIND + 1))
          ;;
        playbook_version)
          PLAYBOOK_VERSION="${!OPTIND}"; OPTIND=$((OPTIND + 1))
          ;;
        toolkit_version)
          TOOLKIT_VERSION="${!OPTIND}"; OPTIND=$((OPTIND + 1))
          ;;
        verbose)
          VERBOSE=true
          ;;
        *)
          echo "Invalid option --${OPTARG}"
          usage
          ;;
      esac
      ;;
    \?)
      echo "Invalid option: -${OPTARG}" >&2
      usage
      ;;
    :)
      echo "Option -${OPTARG} requires an argument." >&2
      usage
      ;;
  esac
done

if [ -z "$REGION" ]; then
  echo "Error: REGION variable is mandatory."
  usage
fi

if [ -z "$PLAYBOOK_NAME" ]; then
  echo "Error: PLAYBOOK_NAME variable is mandatory."
  usage
fi

if [ -z "$PLAYBOOK_BASE_URL" ]; then
  echo "Error: PLAYBOOK_BASE_URL variable is mandatory."
  usage
fi

if [ -z "$VAULT_PASSWORD" ]; then
  echo "Error: VAULT_PASSWORD variable is mandatory."
  usage
fi

if [ "$VERBOSE" = true ]; then
    set -x
fi

# Functions
assert_var() {
    local var_name="$1"
    local var_value="$2"
    if [ -z "$var_value" ]; then
        echo "Error: $var_name is not set." 1>&2
        echo "Error: $var_name is not set."
        exit 1
    fi
}

# Global Variables
PYTHON_BIN=python3
MAIN_SCRIPT_URL=""

identify_os() {
    echo 'identify_os'
    REMOTE_IDENTIFY_OS_SCRIPT="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/${TOOLKIT_VERSION}/identify_os.sh"
    if [ -z "${OS_FAMILY:-}" ]; then
        echo "OS_FAMILY is not defined."
        if [ -f "$LOCAL_IDENTIFY_OS_SCRIPT" ]; then
            echo "Executing local identify_os.sh..."
            source "$LOCAL_IDENTIFY_OS_SCRIPT"
        else
            echo "Local identify_os.sh not found. Executing from remote URL..."
            source <(curl -s "$REMOTE_IDENTIFY_OS_SCRIPT")
        fi
    fi
}

cleanup() {
    if [ -f "$VAULT_PASSWORD_FILE" ]; then
        rm -f "$VAULT_PASSWORD_FILE"
        echo "vault_password file removed."
    fi
}

catch_error() {
    echo "An error occurred in goldenimage_script: '$1'"
    cleanup
}

setup_environment() {
    echo 'setup_environment'
    sudo mkdir /deployment
    sudo chown -R "$(whoami)": /deployment

    if [[ "$OS_FAMILY" == "amzn" && "$OS_VERSION" -eq 2 ]]; then
        echo 'amzn2 tweaks'
        PYTHON_BIN="python3.8"
        MAIN_SCRIPT_URL="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/${TOOLKIT_VERSION}/main_amzn2.sh"
        sudo yum -y erase python3 && sudo amazon-linux-extras install $PYTHON_BIN
    else
        MAIN_SCRIPT_URL="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/${TOOLKIT_VERSION}/main_amzn2023.sh"
    fi

    $PYTHON_BIN -m venv /deployment/ansibleenv
    source /deployment/ansibleenv/bin/activate
}

install_pip() {
    echo 'install_pip'
    local url=$1
    if [[ $url == s3://* ]]; then
        echo "Downloading get-pip from S3..."
        aws s3 cp "$url" - | $PYTHON_BIN
    elif [[ $url == http*://* ]]; then
        echo "Downloading get-pip via HTTP..."
        curl -s "$url" | $PYTHON_BIN
    else
        echo "Unsupported URL scheme: $url" 1>&2
        echo "Unsupported URL scheme: $url"
        exit 1
    fi
}

download_playbook() {
    local base_url=$1
    local name=$2
    local local_folder=$3
    local version=$PLAYBOOK_VERSION
    local s3_folder="$base_url/$name/$version"
    
    if aws s3 ls "$s3_folder" --region $REGION >/dev/null 2>&1; then
        echo "download playbook '$s3_folder'"
        mkdir "$local_folder" 
        aws s3 cp "$s3_folder/" "$local_folder" --recursive --region "$REGION" --exclude '.*' --exclude '*/.*'
        chmod -R 755 "$local_folder"
    else
        echo "S3 folder $s3_folder does not exist. Exiting." 1>&2
        echo "S3 folder $s3_folder does not exist. Exiting."
        exit 1
    fi
}

run_main_script() {
    echo 'run_main_script'
    cd /deployment/playbook
    echo "$VAULT_PASSWORD" > "$VAULT_PASSWORD_FILE"

    if [ ! -f "main.sh" ]; then
        echo "Local main.sh not found. Downloading main.sh script from URL..."
        curl -s "$MAIN_SCRIPT_URL" -o main.sh
    fi
    
    # Construct the command with verbose option if enabled
    if [ "$VERBOSE" = true ]; then
        bash main.sh -e "playbook_name=$PLAYBOOK_NAME" --tags "installation" --verbose
    else
        bash main.sh -e "playbook_name=$PLAYBOOK_NAME" --tags "installation"
    fi

    cleanup
}

main() {
    set -euo pipefail
    echo "Start goldenimage.sh"

    identify_os

    echo "playbook_name: $PLAYBOOK_NAME"

    assert_var "PLAYBOOK_NAME" "$PLAYBOOK_NAME"
    assert_var "PLAYBOOK_BASE_URL" "$PLAYBOOK_BASE_URL"
    assert_var "VAULT_PASSWORD" "$VAULT_PASSWORD"
    assert_var "GET_PIP_URL" "$GET_PIP_URL"
    assert_var "REGION" "$REGION"
    assert_var "PLAYBOOK_VERSION" "$PLAYBOOK_VERSION"

    setup_environment
    install_pip "$GET_PIP_URL"
    download_playbook "$PLAYBOOK_BASE_URL" "$PLAYBOOK_NAME" /deployment/playbook
    run_main_script

    echo "End goldenimage.sh"
}
# Execute the main function and capture errors
{ ERROR=$(main 2>&1 1>&$out); } {out}>&1