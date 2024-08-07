#!/bin/bash

ACCOUNT_ID=""
TOPIC_NAME=""
SKIP_TAGS=""
TAGS=""
EXTRA=""
REGION=""

usage() {
    echo "Usage: $0 --account-id <account-id> --topic-name <topic-name> [-e <extra>] [-r <region>] [--skip-tags <skip-tags>] [--tags <tags>]"
    exit 1
}

while getopts ":e:r:-:" option; do
  case "${option}" in
    e) EXTRA="${OPTARG}";;
    r) REGION="${OPTARG}";;
    -)
      case "${OPTARG}" in
        account-id) ACCOUNT_ID="${!OPTIND}"; OPTIND=$((OPTIND + 1));;
        topic-name) TOPIC_NAME="${!OPTIND}"; OPTIND=$((OPTIND + 1));;
        skip-tags) SKIP_TAGS="${!OPTIND}"; OPTIND=$((OPTIND + 1));;
        tags) TAGS="${!OPTIND}"; OPTIND=$((OPTIND + 1));;
        *) echo "Invalid option --${OPTARG}"; usage;;
      esac
      ;;
    \?) echo "Invalid option: -${OPTARG}" >&2; usage;;
    :) echo "Option -${OPTARG} requires an argument." >&2; usage;;
  esac
done

# Validate mandatory arguments
if [ -z "$ACCOUNT_ID" ]; then
    echo "Error: --account-id is mandatory."
    usage
fi

if [ -z "$TOPIC_NAME" ]; then
    echo "Error: --topic-name is mandatory."
    usage
fi

echo "EXTRA: $EXTRA"
echo "REGION: $REGION"
echo "SKIP_TAGS: $SKIP_TAGS"
echo "TAGS: $TAGS"
echo "ACCOUNT_ID: $ACCOUNT_ID"
echo "TOPIC_NAME: $TOPIC_NAME"

if [ -z "$REGION" ]; then
    REGION=$(ec2-metadata --availability-zone | sed -n 's/.*placement: \([a-zA-Z-]*[0-9]\).*/\1/p')
fi

set -euo pipefail
echo "start main_amzn2023.sh"
[ -f "requirements.txt" ] && pip install -r requirements.txt || pip install -r https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/master/requirements.txt
#export PATH=$PATH:~/.local/bin
export ANSIBLE_ROLES_PATH="$(pwd)/ansible-galaxy/roles"

if [ ! -f "requirements_amzn2023.yml" ]; then
    echo "Local requirements_amzn2023.yml not found. Downloading from URL..."
    curl -O https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/master/requirements_amzn2023.yml
fi
ansible-galaxy install -p roles -r requirements_amzn2023.yml

if [ -f "requirements_extra.yml" ]; then
    echo "Found requirements_extra.yml ..."
    ansible-galaxy install -p roles -r requirements_extra.yml
fi


[[ -n "${EXTRA}" ]] && EXTRA_OPTION="-e \"${EXTRA}\"" || EXTRA_OPTION=""
[[ -n "${SKIP_TAGS}" ]] && SKIP_TAGS_OPTION="--skip-tags \"${SKIP_TAGS}\"" || SKIP_TAGS_OPTION=""
[[ -n "${TAGS}" ]] && TAGS_OPTION="--tags \"${TAGS}\"" || TAGS_OPTION=""

ACCESS_URL="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/master/access.yml"
COMMAND="ansible-playbook --connection=local --inventory 127.0.0.1, --limit 127.0.0.1 main.yml ${EXTRA_OPTION} --vault-password-file vault_password ${TAGS_OPTION} ${SKIP_TAGS_OPTION}"
PLAYBOOK_URL="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/master/main.yml"

if [ ! -f "vars/access.yml" ]; then
    echo "Local vars/access.yml not found. Downloading from URL..."
    curl $ACCESS_URL -o vars/access.yml
fi

if [ ! -f "main.yml" ]; then
    echo "Local main.yml not found. Downloading from URL..."
    curl -O $PLAYBOOK_URL
fi

SYNTAX_CHECK_COMMAND="${COMMAND} --syntax-check"
echo "Running syntax check command: ${SYNTAX_CHECK_COMMAND}"
eval "${SYNTAX_CHECK_COMMAND}"

echo "Running command: ${COMMAND}"
eval "${COMMAND}"