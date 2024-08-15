#!/usr/bin/env bash

# Constants
PYTHON_BIN=python3
MAIN_SCRIPT_URL="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/main_amzn2023.sh"
LOCAL_IDENTIFY_OS_SCRIPT="identify_os.sh"
REMOTE_IDENTIFY_OS_SCRIPT="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/identify_os.sh"
SECRET_NAME="vault_secret"
VAULT_PASSWORD_FILE="vault_password"

# Functions
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

identify_os() {
    if [ -z "${OS_FAMILY:-}" ]; then
        echo "OS_FAMILY is not defined."
        if [ -f "$LOCAL_IDENTIFY_OS_SCRIPT" ]; then
            echo "Executing local identify_os.sh..."
            source "$LOCAL_IDENTIFY_OS_SCRIPT"
        else
            echo "Local identify_os.sh not found. Executing from remote URL..."
            curl -s "$REMOTE_IDENTIFY_OS_SCRIPT" | bash
        fi  
    fi
}

get_metadata_token() {
    curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}

get_instance_tags() {
    local token=$1
    curl -s -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/tags/instance"
}

cleanup() {
    if [ -f "$VAULT_PASSWORD_FILE" ]; then
        rm -f "$VAULT_PASSWORD_FILE"
        echo "vault_password file removed."
    fi
}

catch_error() {
    cleanup
    local instance_id=$(ec2-metadata --instance-id | sed -n 's/.*instance-id: \(i-[a-f0-9]\{17\}\).*/\1/p')
    echo "An error occurred in goldenimage_script: $1"
    aws sns publish --topic-arn "arn:aws:sns:$REGION:$ACCOUNT_ID:$TOPIC_NAME" --message "$1" --subject "$instance_id" --region "$REGION"
}

install_pip() {
    local url=$1
    if [[ $url == s3://* ]]; then
        echo "Downloading get-pip from S3..."
        aws s3 cp "$url" - | $PYTHON_BIN
    elif [[ $url == http*://* ]]; then
        echo "Downloading get-pip via HTTP..."
        curl -s "$url" | $PYTHON_BIN
    else
        echo "Unsupported URL scheme: $url"
        exit 1
    fi
}

setup_environment() {
    sudo mkdir /deployment
    sudo chown -R "$(whoami)": /deployment
    $PYTHON_BIN -m venv /deployment/ansibleenv
    source /deployment/ansibleenv/bin/activate
}

download_playbook() {
    echo "download playbook"
    mkdir /deployment/playbook
    aws s3 cp "$PLAYBOOK_BASE_URL/$PLAYBOOK_NAME/latest/" /deployment/playbook --recursive --region "$REGION" --exclude '.*' --exclude '*/.*'
    chmod -R 755 /deployment/playbook
}

run_main_script() {
    cd /deployment/playbook
    echo "$VAULT_PASSWORD" > "$VAULT_PASSWORD_FILE"

    if [ ! -f "main.sh" ]; then
        echo "Local main.sh not found. Downloading main.sh script from URL..."
        curl -s "$MAIN_SCRIPT_URL" -o main.sh
    fi

    bash main.sh -e "playbook_name=$PLAYBOOK_NAME" --tags "installation"
    cleanup
}

main() {
    set -euo pipefail
    echo "Start goldenimage_script_amzn2023.sh"

    REGION=$(get_region)
    echo "region: $REGION"

    ACCOUNT_ID=$(get_account_id)
    echo "Account ID: $ACCOUNT_ID"

    PARAMETER=$(get_parameter "UserDataYAMLConfig")

    TOPIC_NAME=$(echo "$PARAMETER" | grep 'topic_name' | awk '{print $2}')
    echo "Topic Name: $TOPIC_NAME"

    identify_os

    METADATA_TOKEN=$(get_metadata_token)
    PLAYBOOK_NAME=$(get_instance_tags "$METADATA_TOKEN/playbook_name")
    echo "playbook_name: $PLAYBOOK_NAME"

    GET_PIP_URL=$(echo "$PARAMETER" | grep 'get_pip_url' | awk '{print $2}')
    echo "Get Pip URL: $GET_PIP_URL"

    PLAYBOOK_BASE_URL=$(echo "$PARAMETER" | grep 'playbook_base_url' | awk '{print $2}')
    echo "Playbook Base URL: $PLAYBOOK_BASE_URL"

    VAULT_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$REGION" --query 'SecretString' --output text)

    setup_environment
    install_pip "$GET_PIP_URL"
    download_playbook
    run_main_script

    echo "End goldenimage_script_amzn2023.sh"
}

# Trap errors and execute the catch_error function
trap 'catch_error "$ERROR"' ERR

# Execute the main function and capture errors
{ ERROR=$(main 2>&1 1>&$out); } {out}>&1