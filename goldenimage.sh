#!/usr/bin/env bash

# Constants
PYTHON_BIN=python3
MAIN_SCRIPT_URL="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/main_amzn2023.sh"
LOCAL_IDENTIFY_OS_SCRIPT="identify_os.sh"
REMOTE_IDENTIFY_OS_SCRIPT="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/identify_os.sh"
SECRET_NAME="vault_secret"
VAULT_PASSWORD_FILE="vault_password"
PLAYBOOK_VERSION="latest"

# Functions
assert_var() {
    local var_name="$1"
    local var_value="$2"
    if [ -z "$var_value" ]; then
        echo "Error: $var_name is not set." >&2
        exit 1
    fi
}

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

# Global Variables
REGION=$(get_region)
echo "region: $REGION"
ACCOUNT_ID=$(get_account_id)
echo "account: $ACCOUNT_ID"
PARAMETER=$(get_parameter "UserDataYAMLConfig")
TOPIC_NAME=$(echo "$PARAMETER" | grep 'topic_name' | awk '{print $2}')
echo "topic: $TOPIC_NAME"

identify_os() {
    echo 'identify_os'
    if [ -z "${OS_FAMILY:-}" ]; then
        echo "OS_FAMILY is not defined."
        if [ -f "$LOCAL_IDENTIFY_OS_SCRIPT" ]; then
            echo "Executing local identify_os.sh..."
            source "$LOCAL_IDENTIFY_OS_SCRIPT"
        else
            echo "Local identify_os.sh not found. Executing from remote URL..."
            source <(curl -s "$REMOTE_IDENTIFY_OS_SCRIPT")
        fi
    fi
}

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

cleanup() {
    if [ -f "$VAULT_PASSWORD_FILE" ]; then
        rm -f "$VAULT_PASSWORD_FILE"
        echo "vault_password file removed."
    fi
}

catch_error() {
    echo "An error occurred in goldenimage_script: '$1'"
    cleanup
    local instance_id=$(ec2-metadata --instance-id | sed -n 's/.*instance-id: \(i-[a-f0-9]\{17\}\).*/\1/p')
    aws sns publish --topic-arn "arn:aws:sns:$REGION:$ACCOUNT_ID:$TOPIC_NAME" --message "$1" --subject "$instance_id" --region "$REGION"
}

setup_environment() {
    echo 'setup_environment'
    sudo mkdir /deployment
    sudo chown -R "$(whoami)": /deployment

    if [[ "$OS_FAMILY" == "amzn" && "$OS_VERSION" -eq 2 ]]; then
        echo 'amzn2 tweaks'
        PYTHON_BIN="python3.8"
        yum -y erase python3 && amazon-linux-extras install $PYTHON_BIN
    fi

    $PYTHON_BIN -m venv /deployment/ansibleenv
    source /deployment/ansibleenv/bin/activate
}

install_pip() {
    echo 'install_pip'
    local url=$1
    if [[ $url == s3://* ]]; then
        echo "Downloading get-pip from S3..."
        aws s3 cp "$url" - | $PYTHON_BIN
    elif [[ $url == http*://* ]]; then
        echo "Downloading get-pip via HTTP..."
        curl -s "$url" | $PYTHON_BIN
    else
        echo "Unsupported URL scheme: $url" >&2
        exit 1
    fi
}

download_playbook() {
    local base_url=$1
    local name=$2
    local local_folder=$3
    local s3_folder="$base_url/$name/$PLAYBOOK_VERSION/"

    if aws s3 ls "$s3_folder" >/dev/null 2>&1; then
        echo "download playbook '$s3_folder'"
        mkdir "$local_folder" 
        aws s3 cp "$base_url/$name/$PLAYBOOK_VERSION/" "$local_folder" --recursive --region "$REGION" --exclude '.*' --exclude '*/.*'
        chmod -R 755 "$local_folder"
    else
        echo "S3 folder '$s3_folder' does not exist. Exiting." >&2
        exit 1
    fi
}

run_main_script() {
    echo 'run_main_script'
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
    echo "Start goldenimage.sh"

    identify_os

    METADATA_TOKEN=$(get_metadata_token)
    PLAYBOOK_NAME=$(get_instance_tags "$METADATA_TOKEN" playbook_name)
    echo "playbook_name: $PLAYBOOK_NAME"

    GET_PIP_URL=$(echo "$PARAMETER" | grep 'get_pip_url' | awk '{print $2}')
    echo "Get Pip URL: $GET_PIP_URL"

    PLAYBOOK_BASE_URL=$(echo "$PARAMETER" | grep 'playbook_base_url' | awk '{print $2}')
    echo "Playbook Base URL: $PLAYBOOK_BASE_URL"

    VAULT_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$REGION" --query 'SecretString' --output text)

    assert_var "PLAYBOOK_NAME" "$PLAYBOOK_NAME"
    assert_var "PLAYBOOK_BASE_URL" "$PLAYBOOK_BASE_URL"
    assert_var "VAULT_PASSWORD" "$VAULT_PASSWORD"
    assert_var "GET_PIP_URL" "$GET_PIP_URL"

    setup_environment
    install_pip "$GET_PIP_URL"
    download_playbook "$PLAYBOOK_BASE_URL" "$PLAYBOOK_NAME" /deployment/playbook
    run_main_script

    echo "End goldenimage.sh"
}

# Trap errors and execute the catch_error function
trap 'catch_error "$ERROR"' ERR

# Execute the main function and capture errors
{ ERROR=$(main 2>&1 1>&$out); } {out}>&1