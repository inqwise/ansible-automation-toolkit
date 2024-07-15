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
        skip-tags) SKIP_TAGS="${!OPTIND}"; OPTIND=$((OPTIND + 1));;
        tags) TAGS="${!OPTIND}"; OPTIND=$((OPTIND + 1));;
        account-id) ACCOUNT_ID="${!OPTIND}"; OPTIND=$((OPTIND + 1));;
        topic-name) TOPIC_NAME="${!OPTIND}"; OPTIND=$((OPTIND + 1));;
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

catch_error() {
    INSTANCE_ID=$(ec2-metadata --instance-id | sed -n 's/.*instance-id: \(i-[a-f0-9]\{17\}\).*/\1/p')
    echo "An error occurred in main.sh: $1"
    aws sns publish --topic-arn "arn:aws:sns:$REGION:$ACCOUNT_ID:function:$TOPIC_NAME" --message "$1" --subject "$INSTANCE_ID" --region $REGION
}

main() {
    set -eEuo pipefail
    echo "start main_amzn2.sh"
    echo "extra:${EXTRA:=default}"
    [ -f "requirements.txt" ] && pip3.8 install -r requirements.txt --user virtualenv || pip3.8 install -r https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/master/requirements.txt --user virtualenv
    export PATH=$PATH:~/.local/bin
    export ANSIBLE_ROLES_PATH="$(pwd)/ansible-galaxy/roles"
    [ -f "requirements.yml" ] && ansible-galaxy install -p roles -r requirements.yml || ansible-galaxy install -p roles -r https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/master/requirements.yml

    [[ -n "${EXTRA}" ]] && EXTRA_OPTION="-e \"${EXTRA}\"" || EXTRA_OPTION=""
    [[ -n "${SKIP_TAGS}" ]] && SKIP_TAGS_OPTION="--skip-tags \"${SKIP_TAGS}\"" || SKIP_TAGS_OPTION=""
    [[ -n "${TAGS}" ]] && TAGS_OPTION="--tags \"${TAGS}\"" || TAGS_OPTION=""

    COMMAND="ansible-playbook --connection=local --inventory 127.0.0.1, --limit 127.0.0.1 main.yml ${EXTRA_OPTION} --vault-password-file vault_password ${TAGS_OPTION} ${SKIP_TAGS_OPTION}"
    PLAYBOOK_URL="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/master/main.yml"

    if [ ! -f "main.yml" ]; then
        echo "Local main.yml not found. Downloading from URL..."
        curl -O $PLAYBOOK_URL
    fi

    SYNTAX_CHECK_COMMAND="${COMMAND} --syntax-check"
    echo "Running syntax check command: ${SYNTAX_CHECK_COMMAND}"
    eval "${SYNTAX_CHECK_COMMAND}"

    echo "Running command: ${COMMAND}"
    eval "${COMMAND}"
}
trap 'catch_error "$ERROR"' ERR
{ ERROR=$(main 2>&1 1>&$out); } {out}>&1