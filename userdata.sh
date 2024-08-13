#!/usr/bin/env bash

REGION=$(ec2-metadata --availability-zone | sed -n 's/.*placement: \([a-zA-Z-]*[0-9]\).*/\1/p');
echo "region:$REGION"

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "account_id:$ACCOUNT_ID"

# instance paramaters
METADATA_REQUEST='TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") && curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/tags/instance'

PLAYBOOK_NAME=$(eval $METADATA_REQUEST/playbook_name)
echo "playbook_name:$PLAYBOOK_NAME"

# global parameters
PARAMETER=$(aws ssm get-parameter --name "UserDataYAMLConfig" --query "Parameter.Value" --output text --region $REGION)

TOPIC_NAME=$(echo "$PARAMETER" | grep 'topic_name' | awk '{print $2}')
echo "Topic Name: $TOPIC_NAME"

SECRET_NAME="vault_secret"
VAULT_PASSWORD=$(aws secretsmanager get-secret-value --secret-id $SECRET_NAME --region $REGION --query 'SecretString' --output text)

catch_error () {
    echo "An error occurred in userdata: $1"
    INSTANCE_ID=$(ec2-metadata --instance-id | sed -n 's/.*instance-id: \(i-[a-f0-9]\{17\}\).*/\1/p')
    aws sns publish --topic-arn "arn:aws:sns:$REGION:$ACCOUNT_ID:$TOPIC_NAME" --message "$1" --subject "$INSTANCE_ID" --region $REGION
}
main () {
    set -euo pipefail
    source /deployment/ansibleenv/bin/activate
    cd /deployment/playbook
    export ANSIBLE_VERBOSITY=0
    export ANSIBLE_DISPLAY_SKIPPED_HOSTS=false
    echo "$VAULT_PASSWORD" > vault_password
    bash main.sh -r $REGION -e "playbook_name=$PLAYBOOK_NAME" --topic-name $TOPIC_NAME --account-id $ACCOUNT_ID --tags configuration
    rm vault_password
}
trap 'catch_error "$ERROR"' ERR
{ ERROR=$(main 2>&1 1>&$out); } {out}>&1