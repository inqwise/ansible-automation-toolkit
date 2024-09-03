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
SKIP_REMOTE_REQUIREMENTS="${SKIP_REMOTE_REQUIREMENTS:-false}"

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
    echo "  --skip-remote-requirements    Skip downloading remote requirements."
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
        skip-remote-requirements)
          SKIP_REMOTE_REQUIREMENTS=true
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
        sudo