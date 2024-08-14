#!/bin/bash

# File path to the manifest.json
manifest_file="manifest.json"
# Output file path
output_file="goldenimage_result.json"
# Local script file
local_script="update_ami-test.sh"
# Remote script URL
remote_script_url="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/update_ami.sh"

# Read the last_run_uuid from the manifest.json
last_run_uuid=$(jq -r '.last_run_uuid' "$manifest_file")

# Find the object in the builds array with the matching packer_run_uuid
last_run_object=$(jq --arg uuid "$last_run_uuid" '.builds[] | select(.packer_run_uuid == $uuid)' "$manifest_file")

# Check if the last_run_object was found
if [ -n "$last_run_object" ]; then
    echo "Matching object found:"
    
    # Generate the result_object with required fields
    result_object=$(echo "$last_run_object" | jq '{
        timestamp: .build_time,
        all_amis: (.artifact_id | split(",") | map(split(":") | { (.[0]): .[1] }) | add),
        app: .custom_data.app,
        profile: .custom_data.profile,
        region: .custom_data.region,
        version: .custom_data.version
    } | . + {ami: .all_amis[.region]}')
    
    # Save the result_object to goldenimage_result.json
    echo "$result_object" | jq . > "$output_file"
    
    echo "Result object saved to $output_file"
    
    # Extract values for script arguments
    template_name=$(echo "$result_object" | jq -r '.app')
    new_ami_id=$(echo "$result_object" | jq -r '.ami')
    version_description=$(echo "$result_object" | jq -r '.version')
    aws_profile=$(echo "$result_object" | jq -r '.profile')
    aws_region=$(echo "$result_object" | jq -r '.region')

    # Check if local script exists and execute it, otherwise execute the remote script
    if [ -f "$local_script" ]; then
        echo "Local script found, executing $local_script..."
        bash "$local_script" -t "$template_name" -a "$new_ami_id" -d "$version_description" -p "$aws_profile" -r "$aws_region" -m
    else
        echo "Local script not found, executing remote script from $remote_script_url..."
        curl -s "$remote_script_url" | bash -s -- -t "$template_name" -a "$new_ami_id" -d "$version_description" -p "$aws_profile" -r "$aws_region" -m
    fi
    
    echo "Script executed with provided arguments."
else
    echo "No matching object found."
fi