#!/usr/bin/env bash
set -euo pipefail

SECRET_NAME="vault_secret"

get_region() {
    ec2-metadata --availability-zone | sed -n 's/.*placement: \([a-zA-Z-]*[0-9]\).*/\1/p'
}

get_account_id() {
    aws sts get-caller-identity --query "Account" --output text
}

get_parameter() {
    local name=$1
    aws ssm get-parameter --name "$name" --query "Parameter.Value" --output text --region "$REGION"
}

REGION=$(get_region)
echo "region: $REGION"

PARAMETER=$(get_parameter "UserDataYAMLConfig")

get_metadata_token() {
    curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}

get_instance_tags() {
    local token=$1
    local tag=$2
    local url="http://169.254.169.254/latest/meta-data/tags/instance/$tag"

    # Perform the curl request and capture the output and the HTTP status code
    response=$(curl -s -o /dev/null -w "%{http_code}" -H "X-aws-ec2-metadata-token: $token" "$url")

    # Check if the status code is 200
    if [[ "$response" -eq 200 ]]; then
        # If 200, fetch the actual tag value
        curl -s -H "X-aws-ec2-metadata-token: $token" "$url"
    else
        echo "Error: Failed to retrieve instance tag $tag. HTTP status code: $response" >&2
        exit 1
    fi
}

METADATA_TOKEN=$(get_metadata_token)

PLAYBOOK_NAME=$(get_instance_tags "$METADATA_TOKEN" playbook_name)
echo "playbook_name: $PLAYBOOK_NAME"

GET_PIP_URL=$(echo "$PARAMETER" | grep 'get_pip_url' | awk '{print $2}')
echo "Get Pip URL: $GET_PIP_URL"

PLAYBOOK_BASE_URL=$(echo "$PARAMETER" | grep 'playbook_base_url' | awk '{print $2}')
echo "Playbook Base URL: $PLAYBOOK_BASE_URL"

VAULT_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$REGION" --query 'SecretString' --output text)

curl -o /tmp/goldenimage.sh https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/packer/goldenimage.sh
bash /tmp/goldenimage.sh --get_pip_url "$GET_PIP_URL" --playbook_name "$PLAYBOOK_NAME" --playbook_base_url "$PLAYBOOK_BASE_URL" -r "$REGION" --vault_password $VAULT_PASSWORD --playbook_version