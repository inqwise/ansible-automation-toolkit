#!/bin/bash

SKIP_TAGS=""
TAGS=""
EXTRA=""
REGION=""

while getopts ":e:r:-:" option; do
  case "${option}" in
    e) EXTRA="${OPTARG}";;
    r) REGION="${OPTARG}";;
    -)
      case "${OPTARG}" in
        skip-tags) SKIP_TAGS="${!OPTIND}"; OPTIND=$((OPTIND + 1));;
        tags) TAGS="${!OPTIND}"; OPTIND=$((OPTIND + 1));;
        *) echo "Invalid option --${OPTARG}"; exit 1;;
      esac
      ;;
    \?) echo "Invalid option: -${OPTARG}" >&2; exit 1;;
    :) echo "Option -${OPTARG} requires an argument." >&2; exit 1;;
  esac
done

echo "EXTRA: $EXTRA"
echo "REGION: $REGION"
echo "SKIP_TAGS: $SKIP_TAGS"
echo "TAGS: $TAGS"

if [ -z "$REGION" ]; then
    REGION=$(ec2-metadata --availability-zone | sed -n 's/.*placement: \([a-zA-Z-]*[0-9]\).*/\1/p')
fi

catch_error() {
    INSTANCE_ID=$(ec2-metadata --instance-id | sed -n 's/.*instance-id: \(i-[a-f0-9]\{17\}\).*/\1/p')
    echo "An error occurred: $1"
    aws sns publish --topic-arn "arn:aws:sns:$REGION:992382682634:errors" --message "$1" --subject "$INSTANCE_ID" --region $REGION
}

main() {
    set -euxo pipefail
    pip install -r requirements.txt --user virtualenv --timeout 60
    export PATH=$PATH:~/.local/bin
    export ANSIBLE_ROLES_PATH="$(pwd)/ansible-common-collection/roles"
    ansible-galaxy install -r requirements.yml

    [[ -n "${EXTRA}" ]] && EXTRA_OPTION="-e \"${EXTRA}\"" || EXTRA_OPTION=""
    [[ -n "${SKIP_TAGS}" ]] && SKIP_TAGS_OPTION="--skip-tags \"${SKIP_TAGS}\"" || SKIP_TAGS_OPTION=""
    [[ -n "${TAGS}" ]] && TAGS_OPTION="--tags \"${TAGS}\"" || TAGS_OPTION=""

    COMMAND="ansible-playbook --connection=local --inventory 127.0.0.1, --limit 127.0.0.1 main.yml ${EXTRA_OPTION} --vault-password-file vault_password ${TAGS_OPTION} ${SKIP_TAGS_OPTION}"

    SYNTAX_CHECK_COMMAND="${COMMAND} --syntax-check"
    echo "Running syntax check command: ${SYNTAX_CHECK_COMMAND}"
    eval "${SYNTAX_CHECK_COMMAND}"

    echo "Running command: ${COMMAND}"
    eval "${COMMAND}"
}

trap 'catch_error "$ERROR"' ERR
{ ERROR=$(main 2>&1 1>&$out); } {out}>&1