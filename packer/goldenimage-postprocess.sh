#!/bin/bash

set -euo pipefail

# File path to the manifest.json
manifest_file="manifest.json"
# Output file path
output_file="goldenimage_result.json"
# Local script file
local_script="update_template_ami-test.sh"
# Remote script URL
remote_script_url="https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/update_tempalte_ami.sh"

# Ensure the manifest.json exists
if [ ! -f "$manifest_file" ]; then
    echo "Error: Manifest file '$manifest_file' not found."
    exit 1
fi

# Read the last_run_uuid from the manifest.json
last_run_uuid=$(jq -r '.last_run_uuid // empty' "$manifest_file")
if [ -z "$last_run_uuid" ]; then
    echo "Error: 'last_run_uuid' not found in the manifest."
    exit 1
fi

# Find the object in the builds array with the matching packer_run_uuid
last_run_object=$(jq --arg uuid "$last_run_uuid" '.builds[] | select(.packer_run_uuid == $uuid)' "$manifest_file")
if [ -z "$last_run_object" ]; then
    echo "No matching object found in 'builds' for UUID: $last_run_uuid."
    exit 1
fi

echo "Matching object found."

# Generate the result_object with required fields
result_object=$(echo "$last_run_object" | jq '{
    timestamp: .build_time,
    all_amis: (.artifact_id | split(",") | map(split(":") | { (.[0]): .[1] }) | add),
    app: .custom_data.app,
    profile: .custom_data.profile,
    region: .custom_data.region,
    run_region: .custom_data.run_region,
    version: .custom_data.version
} | . + {ami: .all_amis[.run_region]}')

# Ensure the result_object has required keys
if [ -z "$result_object" ]; then
    echo "Error: Could not parse the required fields from the matching object."
    exit 1
fi

# Save the result_object to goldenimage_result.json
echo "$result_object" | jq . > "$output_file"
echo "Result object saved to $output_file."

# Extract values for script arguments
template_name=$(echo "$result_object" | jq -r '.app // empty')
new_ami_id=$(echo "$result_object" | jq -r '.all_amis[.region] // empty')
version_description=$(echo "$result_object" | jq -r '.version // empty')
aws_profile=$(echo "$result_object" | jq -r '.profile // empty')
aws_region=$(echo "$result_object" | jq -r '.region // empty')

# Remove local goldenimage packer file if it exists
local_goldenimage_packer="goldenimage.pkr.hcl"
if [ -f "$local_goldenimage_packer" ]; then
    rm "$local_goldenimage_packer"
    echo "Removed local goldenimage packer file."
fi