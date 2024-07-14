#!/usr/bin/env bash
PARAMETER=$(aws ssm get-parameter --name "UserDataYAMLConfig" --query "Parameter.Value" --output text)

METADATA_REQUEST='TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") && curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/tags/instance'

PLAYBOOK_BASE_URL=$(echo "$PARAMETER" | grep 'playbook_base_url' | awk '{print $2}')
echo "Playbook Base URL: $PLAYBOOK_BASE_URL"

GET_PIP_URL=$(echo "$PARAMETER" | grep 'get_pip_url' | awk '{print $2}')
echo "Get Pip URL: $GET_PIP_URL"

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "Account ID: $ACCOUNT_ID"

PLAYBOOK_NAME=$(eval $METADATA_REQUEST/playbook_name)
echo "playbook_name:$PLAYBOOK_NAME"

FUNCTION_ARN_NAME=$(echo "$PARAMETER" | grep 'function_arn_name' | awk '{print $2}')
echo "Function Arn Name: $FUNCTION_ARN_NAME"

REGION=$(ec2-metadata --availability-zone | sed -n 's/.*placement: \([a-zA-Z-]*[0-9]\).*/\1/p');
echo "region:$REGION"

SECRET_NAME="vault_secret"
VAULT_PASSWORD=$(aws secretsmanager get-secret-value --secret-id $SECRET_NAME --region $REGION --query 'SecretString' --output text)
echo "Secret:$VAULT_PASSWORD"

catch_error () {
    INSTANCE_ID=$(ec2-metadata --instance-id | sed -n 's/.*instance-id: \(i-[a-f0-9]\{17\}\).*/\1/p')
    echo "An error occurred: $1"
    aws sns publish --topic-arn "arn:aws:sns:$REGION:$ACCOUNT_ID:function:$FUNCTION_ARN_NAME" --message "$1" --subject "$INSTANCE_ID" --region $REGION
}
main () {
    set -euxo pipefail
    echo "Start userdata_amzn2023.sh"
    aws s3 cp $GET_PIP_URL - | python3
    aws s3 sync $PLAYBOOK_BASE_URL/$PLAYBOOK_NAME /tmp/$PLAYBOOK_NAME --region $REGION && cd /tmp/$PLAYBOOK_NAME
    echo "$VAULT_PASSWORD" > /vault_password
    curl -s https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/master/main_amzn2023.sh | bash -s -- -r $REGION -e $FUNCTION_ARN_NAME $ACCOUNT_ID
    rm /vault_password
    echo "End user data"
}
trap 'catch_error "$ERROR"' ERR
{ ERROR=$(main 2>&1 1>&$out); } {out}>&1