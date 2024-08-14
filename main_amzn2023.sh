#!/bin/bash

OFFLINE=false
TEST_MODE=false
PIP_COMMAND="pip"

usage() {
    echo "Usage: $0 [--offline] [--test]"
    exit 1
}

while getopts ":-:" option; do
  case "${option}" in
    -)
      case "${OPTARG}" in
        offline) OFFLINE=true;;
        test) TEST_MODE=true;;
        *) echo "Invalid option --${OPTARG}"; usage;;
      esac
      ;;
    \?) echo "Invalid option: -${OPTARG}" >&2; usage;;
    :) echo "Option -${OPTARG} requires an argument." >&2; usage;;
  esac
done

set -euo pipefail
echo "start main_amzn2023.sh"

# Modify file names if TEST_MODE is enabled
if [ "$TEST_MODE" = true ]; then
    echo "Test mode enabled. Using '-test' suffix for local files."

    REQUIREMENTS_TXT="requirements-test.txt"
    REQUIREMENTS_YML="requirements-test.yml"
    MAIN_YML="main-test.yml"
else
    REQUIREMENTS_TXT="requirements.txt"
    REQUIREMENTS_YML="requirements.yml"
    MAIN_YML="main.yml"
fi

# Handle pip installation
if [ "$OFFLINE" = true ]; then
    echo "Running in offline mode."
    [ -f "$REQUIREMENTS_TXT" ] && $PIP_COMMAND install --no-index --no-deps -r $REQUIREMENTS_TXT || echo "$REQUIREMENTS_TXT not found locally and cannot be installed in offline mode."
else
    [ -f "$REQUIREMENTS_TXT" ] && $PIP_COMMAND install -r $REQUIREMENTS_TXT || $PIP_COMMAND install -r https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/requirements.txt
fi

if [ ! -f "$REQUIREMENTS_YML" ]; then
    if [ "$OFFLINE" = true ]; then
        echo "$REQUIREMENTS_YML not found locally and cannot be downloaded in offline mode."
        exit 1
    else
        echo "Local $REQUIREMENTS_YML not found. Downloading from URL..."
        curl https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/requirements_amzn2023.yml -o $REQUIREMENTS_YML
    fi
fi

GALAXY_COMMAND="ansible-galaxy install"

if [ "$OFFLINE" = true ]; then
    GALAXY_COMMAND="$GALAXY_COMMAND --ignore-errors"
fi

$GALAXY_COMMAND -r $REQUIREMENTS_YML

if [ -f "requirements_extra.yml" ]; then
    echo "Found requirements_extra.yml ..."
    $GALAXY_COMMAND -r $REQUIREMENTS_YML
fi

ACCESS_URL="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/access.yml"
COMMAND="ansible-playbook --connection=local --inventory 127.0.0.1, --limit 127.0.0.1 $MAIN_YML --vault-password-file vault_password"
PLAYBOOK_URL="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/main.yml"

if [ ! -f "vars/access.yml" ]; then
    if [ "$OFFLINE" = true ]; then
        echo "vars/access.yml not found locally and cannot be downloaded in offline mode."
        exit 1
    else
        echo "Local vars/access.yml not found. Downloading from URL..."
        curl $ACCESS_URL -o vars/access.yml
    fi
fi

if [ ! -f "$MAIN_YML" ]; then
    if [ "$OFFLINE" = true ]; then
        echo "$MAIN_YML not found locally and cannot be downloaded in offline mode."
        exit 1
    else
        echo "Local $MAIN_YML not found. Downloading from URL..."
        curl -O $PLAYBOOK_URL
    fi
fi

SYNTAX_CHECK_COMMAND="${COMMAND} --syntax-check"
echo "Running syntax check command: ${SYNTAX_CHECK_COMMAND}"
eval "${SYNTAX_CHECK_COMMAND}"

if [ "$TEST_MODE" = true ]; then
    echo "Test mode enabled. Skipping actual playbook execution."
else
    echo "Running command: ${COMMAND}"
    eval "${COMMAND}"
fi