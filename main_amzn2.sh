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
    set -eEuo pipefail
    #yum install jq -y
    #EXTRA=$(echo "${EXTRA:=\{\}}" |  jq --slurp --compact-output --raw-output 'reduce .[] as $item ({}; . * $item)')
    echo "extra:${EXTRA:=default}"
    pip3.8 install -r requirements.txt --timeout 60
    export PATH=$PATH:/usr/local/bin
    export ANSIBLE_ROLES_PATH="$(pwd)/ansible-galaxy/roles"
    ansible-galaxy install -p roles -r requirements.yml
    ansible-playbook --connection=local --inventory 127.0.0.1, --limit 127.0.0.1 main.yml --syntax-check
    ansible-playbook --connection=local --inventory 127.0.0.1, --limit 127.0.0.1 main.yml -e $EXTRA --vault-password-file vault_password
    # --skip-tags openvpn 
}
trap 'catch_error "$ERROR"' ERR
{ ERROR=$(main 2>&1 1>&$out); } {out}>&1


#ansible-playbook --vault-password-file /tmp/ansible-openvpn/secret main.yml --syntax-check
#ansible-playbook --vault-password-file /tmp/ansible-openvpn/secret --connection=local --inventory 127.0.0.1, --limit 127.0.0.1 main.yml