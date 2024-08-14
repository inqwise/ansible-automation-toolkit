#!/bin/bash

SKIP_TAGS=""
TAGS=""
EXTRA=""
OFFLINE=false
TEST_MODE=false
PIP_COMMAND="pip"

usage() {
    echo "Usage: $0 [-e <extra>] [--skip-tags <skip-tags>] [--tags <tags>] [--offline] [--test]"
    exit 1
}

while getopts ":e:-:" option; do
  case "${option}" in
    e) EXTRA="${OPTARG}";;
    -)
      case "${OPTARG}" in
        skip-tags) SKIP_TAGS="${!OPTIND}"; OPTIND=$((OPTIND + 1));;
        tags) TAGS="${!OPTIND}"; OPTIND=$((OPTIND + 1));;
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

GALAXY_ROLE_COMMAND="ansible-galaxy role install"
GALAXY_COLLECTION_COMMAND="ansible-galaxy collection install"

if [ "$OFFLINE" = true ]; then
    GALAXY_ROLE_COMMAND="$GALAXY_ROLE_COMMAND --ignore-errors"
    GALAXY_COLLECTION_COMMAND="$GALAXY_COLLECTION_COMMAND --ignore-errors"
fi

$GALAXY_ROLE_COMMAND -r $REQUIREMENTS_YML -p roles
$GALAXY_COLLECTION_COMMAND -r $REQUIREMENTS_YML -p ./collections

if [ -f "requirements_extra.yml" ]; then
    echo "Found requirements_extra.yml ..."
    $GALAXY_ROLE_COMMAND -r requirements_extra.yml -p roles
    $GALAXY_COLLECTION_COMMAND -r requirements_extra.yml -p ./collections
fi

[[ -n "${EXTRA}" ]] && EXTRA_OPTION="-e \"${EXTRA}\"" || EXTRA_OPTION=""
[[ -n "${SKIP_TAGS}" ]] && SKIP_TAGS_OPTION="--skip-tags \"${SKIP_TAGS}\"" || SKIP_TAGS_OPTION=""
[[ -n "${TAGS}" ]] && TAGS_OPTION="--tags \"${TAGS}\"" || TAGS_OPTION=""

ACCESS_URL="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/access.yml"
COMMAND="ansible-playbook --connection=local --inventory 127.0.0.1, --limit 127.0.0.1 $MAIN_YML ${EXTRA_OPTION} --vault-password-file vault_password ${TAGS_OPTION} ${SKIP_TAGS_OPTION}"
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