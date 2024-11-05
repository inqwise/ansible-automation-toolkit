#!/bin/bash

# -----------------------------------------------------------------------------
# Copy AWS AMI Script
# -----------------------------------------------------------------------------

set -o errexit
set -o nounset
set -o pipefail

# Color Definitions
COLOR='\033[1;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

export AWS_DEFAULT_OUTPUT="json"

usage() {
    cat << EOF
Usage: ${0} -s source_profile -d destination_profile -a ami_id [-N name] [-k key] [-l source_region] [-r destination_region] [-n] [-t] [-u tag:value] [-h]

Options:
  -s,               AWS CLI profile name for AMI source account.
  -d,               AWS CLI profile name for AMI destination account.
  -a,               ID of AMI to be copied.
  -N,               Name for new AMI.
  -l,               Region of the AMI to be copied.
  -r,               Destination region for copied AMI.
  -n,               Enable ENA support on new AMI. (Optional)
  -t,               Copy Tags. (Optional)
  -k,               Specific KMS Key ID for snapshot re-encryption in target AWS account. (Optional)
  -u,               Update an existing or create a new tag with this value. Valid only with -t. Format: key:value (Optional)
  -h,               Show this help message.

By default, the currently specified region for the source and destination AWS CLI profiles will be used, and the default Amazon-managed KMS Key for EBS will be applied.
EOF
}

die() {
    echo -e "${RED}$(basename -- "$0"): error: $*${NC}" >&2
    exit 1
}

# Checking dependencies
command -v jq >/dev/null 2>&1 || die "jq is required but not installed. Aborting. See https://stedolan.github.io/jq/download/"
command -v aws >/dev/null 2>&1 || die "AWS CLI is required but not installed. Aborting. See https://docs.aws.amazon.com/cli/latest/userguide/installing.html"

# Initialize variables
TAG_OPT=""
UPSERT_TAG_OPT=""
ENA_OPT=""
CMK_OPT=""

# Parse options
while getopts ":s:d:a:N:l:r:k:u:nth" opt; do
    case $opt in
        h)
            usage
            exit 0
            ;;
        s)
            SRC_PROFILE="${OPTARG}"
            ;;
        d)
            DST_PROFILE="${OPTARG}"
            ;;
        a)
            AMI_ID="${OPTARG}"
            ;;
        N)
            AMI_NAME="${OPTARG}"
            ;;
        l)
            SRC_REGION="${OPTARG}"
            ;;
        r)
            DST_REGION="${OPTARG}"
            ;;
        k)
            CMK_ID="${OPTARG}"
            ;;
        u)
            UPSERT_TAG_OPT="${OPTARG}"
            ;;
        n)
            ENA_OPT="--ena-support"
            ;;
        t)
            TAG_OPT="y"
            ;;
        \?)
            die "Invalid option: -${OPTARG}"
            ;;
        :)
            die "Option -${OPTARG} requires an argument."
            ;;
    esac
done

# Validate required parameters
if [[ -z "${SRC_PROFILE:-}" || -z "${DST_PROFILE:-}" || -z "${AMI_ID:-}" ]]; then
    usage
    die "Missing required parameters."
fi

# Get default regions if not supplied
if [[ -z "${SRC_REGION:-}" ]]; then
    SRC_REGION=$(aws configure get region --profile "${SRC_PROFILE}") || die "Unable to determine the source region."
fi

if [[ -z "${DST_REGION:-}" ]]; then
    DST_REGION=$(aws configure get region --profile "${DST_PROFILE}") || die "Unable to determine the destination region."
fi

echo -e "${COLOR}Source region:${NC} ${SRC_REGION}"
echo -e "${COLOR}Destination region:${NC} ${DST_REGION}"

# Get source and destination account IDs
SRC_ACCT_ID=$(aws sts get-caller-identity --profile "${SRC_PROFILE}" --region "${SRC_REGION}" --query Account --output text) || die "Unable to get the source account ID. Aborting."
echo -e "${COLOR}Source account ID:${NC} ${SRC_ACCT_ID}"

DST_ACCT_ID=$(aws sts get-caller-identity --profile "${DST_PROFILE}" --region "${DST_REGION}" --query Account --output text) || die "Unable to get the destination account ID. Aborting."
echo -e "${COLOR}Destination account ID:${NC} ${DST_ACCT_ID}"

# Check if optional destination CMK exists in target region
if [[ -n "${CMK_ID:-}" ]]; then
    if aws --profile "${DST_PROFILE}" --region "${DST_REGION}" kms describe-key --key-id "${CMK_ID}" --query 'KeyMetadata.Enabled' --output text | grep -q "^True$"; then
        echo -e "${COLOR}Validated destination KMS Key:${NC} ${CMK_ID}"
    else
        die "KMS Key ${CMK_ID} does not exist, is in the wrong region, or is not enabled. Aborting."
    fi

    CMK_OPT="--kms-key-id ${CMK_ID} --encrypted"
else
    CMK_OPT=""
fi

# Describe the source AMI
AMI_DETAILS=$(aws ec2 describe-images --profile "${SRC_PROFILE}" --region "${SRC_REGION}" --image-id "${AMI_ID}" --query 'Images[0]') || die "Unable to describe the AMI in the source account. Aborting."

# Retrieve the snapshot IDs
SNAPSHOT_IDS=$(echo "${AMI_DETAILS}" | jq -r '.BlockDeviceMappings[] | select(has("Ebs")) | .Ebs.SnapshotId') || die "Unable to get the snapshot IDs from AMI. Aborting."
echo -e "${COLOR}Snapshots found:${NC} ${SNAPSHOT_IDS}"

# Retrieve unique KMS Key IDs used in snapshots
KMS_KEY_IDS=$(aws ec2 describe-snapshots --profile "${SRC_PROFILE}" --region "${SRC_REGION}" --snapshot-ids ${SNAPSHOT_IDS} --query 'Snapshots[?Encrypted==`true`].KmsKeyId' --output text | tr '\t' '\n' | sort -u) || die "Unable to get KMS Key IDs from the snapshots. Aborting."

if [[ -n "${KMS_KEY_IDS}" ]]; then
    echo -e "${COLOR}Customer managed KMS key(s) used on source AMI:${NC} ${KMS_KEY_IDS}"
    # Iterate over the Keys and create the Grants
    while IFS= read -r key; do
        KEY_MANAGER=$(aws kms describe-key --key-id "${key}" --query "KeyMetadata.KeyManager" --profile "${SRC_PROFILE}" --region "${SRC_REGION}" --output text) || die "Unable to retrieve the Key Manager information. Aborting."
        if [[ "${KEY_MANAGER}" == "AWS" ]]; then
            die "The Default AWS/EBS key is being used by the snapshot. Unable to proceed. Aborting."
        fi
        if [[ "${SRC_PROFILE}" != "${DST_PROFILE}" ]]; then
            aws kms --profile "${SRC_PROFILE}" --region "${SRC_REGION}" create-grant --key-id "${key}" --grantee-principal "arn:aws:iam::${DST_ACCT_ID}:root" --operations DescribeKey Decrypt CreateGrant >/dev/null || die "Unable to create a KMS grant for the destination account. Aborting."
            echo -e "${COLOR}Grant created for KMS Key:${NC} ${key}"
        fi
    done <<< "${KMS_KEY_IDS}"
else
    echo -e "${COLOR}No encrypted EBS Volumes were found in the source AMI!${NC}"
fi

# Iterate over the snapshots, adding permissions for the destination account and copying
declare -a SRC_SNAPSHOT DST_SNAPSHOT
i=0
while IFS= read -r snapshotid; do
    if [[ "${SRC_PROFILE}" != "${DST_PROFILE}" ]]; then
        aws ec2 --profile "${SRC_PROFILE}" --region "${SRC_REGION}" modify-snapshot-attribute --snapshot-id "${snapshotid}" --attribute createVolumePermission --operation-type add --user-ids "${DST_ACCT_ID}" || die "Unable to add permissions on snapshot ${snapshotid} for the destination account. Aborting."
        echo -e "${COLOR}Permission added to Snapshot:${NC} ${snapshotid}"
    fi
    SRC_SNAPSHOT[i]="${snapshotid}"
    echo -e "${COLOR}Copying Snapshot:${NC} ${snapshotid}"
    DST_SNAPSHOT[i]=$(aws ec2 copy-snapshot --profile "${DST_PROFILE}" --region "${DST_REGION}" --source-region "${SRC_REGION}" --source-snapshot-id "${snapshotid}" --description "Copied from ${snapshotid} (${SRC_ACCT_ID}|${SRC_REGION})" ${CMK_OPT} --query SnapshotId --output text) || die "Unable to copy snapshot ${snapshotid}. Aborting."
    echo -e "${COLOR}Copied Snapshot:${NC} ${DST_SNAPSHOT[i]}"
    i=$((i + 1))

    # Throttle snapshot copy requests to avoid hitting concurrency limits
    SIM_SNAP=$(aws ec2 describe-snapshots --profile "${DST_PROFILE}" --region "${DST_REGION}" --filters Name=status,Values=pending --query 'Snapshots[].SnapshotId' --output text | wc -w)
    while [[ ${SIM_SNAP} -ge 5 ]]; do
        echo -e "${COLOR}Too many concurrent Snapshots (${SIM_SNAP}), waiting...${NC}"
        sleep 30
        SIM_SNAP=$(aws ec2 describe-snapshots --profile "${DST_PROFILE}" --region "${DST_REGION}" --filters Name=status,Values=pending --query 'Snapshots[].SnapshotId' --output text | wc -w)
    done
done <<< "${SNAPSHOT_IDS}"

# Wait briefly to ensure all snapshot copy operations are registered
sleep 1

# Wait for EBS snapshots to be completed
echo -e "${COLOR}Waiting for all EBS Snapshot copies to complete. This may take a few minutes...${NC}"
i=0
for snapshotid in "${DST_SNAPSHOT[@]}"; do
    echo -e "${COLOR}Waiting for Snapshot:${NC} ${snapshotid} to complete..."
    aws ec2 wait snapshot-completed --snapshot-ids "${snapshotid}" --profile "${DST_PROFILE}" --region "${DST_REGION}" || die "Failed while waiting for snapshot ${snapshotid} to complete. Aborting."
    echo -e "${COLOR}Snapshot completed:${NC} ${snapshotid}"
    i=$((i + 1))
done
echo -e "${COLOR}All EBS Snapshot copies completed.${NC}"

# Update AMI_DETAILS with new snapshot IDs
sLen=${#SRC_SNAPSHOT[@]}
for (( i=0; i<${sLen}; i++ )); do
    echo -e "${COLOR}Snapshot${NC} ${SRC_SNAPSHOT[i]} ${COLOR}copied as${NC} ${DST_SNAPSHOT[i]}"
    AMI_DETAILS=$(echo "${AMI_DETAILS}" | sed -e "s/${SRC_SNAPSHOT[i]}/${DST_SNAPSHOT[i]}/g")
done

# Copy Snapshot Tags if requested
if [[ "${TAG_OPT}" == "y" ]]; then
    for (( i=0; i<${sLen}; i++ )); do
        SNAPSHOT_DETAILS=$(aws ec2 describe-snapshots --profile "${SRC_PROFILE}" --region "${SRC_REGION}" --snapshot-id "${SRC_SNAPSHOT[i]}" --query 'Snapshots[0].Tags' || die "Unable to describe snapshot ${SRC_SNAPSHOT[i]} in the source account. Aborting.")
        if [[ "${SNAPSHOT_DETAILS}" != "null" ]]; then
            aws ec2 create-tags --resources "${DST_SNAPSHOT[i]}" --tags "$(echo "${SNAPSHOT_DETAILS}" | jq -c '.[]')" --profile "${DST_PROFILE}" --region "${DST_REGION}" || die "Unable to add tags to snapshot ${DST_SNAPSHOT[i]} in the destination account. Aborting."
            echo -e "${COLOR}Tags copied for Snapshot:${NC} ${DST_SNAPSHOT[i]}"

            if [[ -n "${UPSERT_TAG_OPT}" ]]; then
                IFS=':' read -r TAG_KEY TAG_VALUE <<< "${UPSERT_TAG_OPT}"
                if [[ -n "${TAG_KEY}" && -n "${TAG_VALUE}" ]]; then
                    aws ec2 create-tags --resources "${DST_SNAPSHOT[i]}" --tags Key="${TAG_KEY}",Value="${TAG_VALUE}" --profile "${DST_PROFILE}" --region "${DST_REGION}" || die "Unable to add/update tag '${TAG_KEY}:${TAG_VALUE}' to snapshot ${DST_SNAPSHOT[i]} in the destination account. Aborting."
                    echo -e "${COLOR}Tag '${TAG_KEY}:${TAG_VALUE}' added to Snapshot:${NC} ${DST_SNAPSHOT[i]}"
                else
                    echo -e "${RED}Invalid UPSERT_TAG_OPT format. Expected key:value. Bypassing...${NC}"
                fi
            fi
        else
            echo -e "${COLOR}No tags found for Snapshot:${NC} ${SRC_SNAPSHOT[i]}"
        fi
    done
fi

# Define a name for the new AMI
NAME=$(echo "${AMI_DETAILS}" | jq -r '.Name')
if [[ -n "${AMI_NAME:-}" ]]; then
    NEW_NAME="${AMI_NAME}"
else
    now="$(date +%s)"
    NEW_NAME="Copy of ${NAME} ${now}"
fi

# Prepare the JSON data for the new AMI, removing non-idempotent and read-only fields
NEW_AMI_DETAILS=$(echo "${AMI_DETAILS}" | jq --arg NAME "${NEW_NAME}" '
    .Name = $NAME |
    walk(if type == "object" then del(.Encrypted) else . end) |
    del(
        .Tags,
        .Platform,
        .PlatformDetails,
        .UsageOperation,
        .ImageId,
        .CreationDate,
        .OwnerId,
        .ImageLocation,
        .State,
        .ImageType,
        .RootDeviceType,
        .Hypervisor,
        .Public,
        .EnaSupport,
        .ProductCodes,
        .SourceInstanceId,
        .DeregistrationProtection,
        .LastLaunchedTime
    )
')

# Optional: Validate JSON structure
echo "${NEW_AMI_DETAILS}" | jq . >/dev/null || die "JSON payload for register-image is invalid."

# Optional: Save JSON for debugging
echo "${NEW_AMI_DETAILS}" | jq . > /tmp/new_ami_details.json
echo -e "${COLOR}Prepared JSON for register-image is saved at /tmp/new_ami_details.json${NC}"

# Register the new AMI in the destination account
CREATED_AMI=$(aws ec2 register-image --profile "${DST_PROFILE}" --region "${DST_REGION}" ${ENA_OPT} --cli-input-json "${NEW_AMI_DETAILS}" --query ImageId --output text) || die "Unable to register AMI in the destination account. Aborting."
echo -e "${COLOR}AMI created successfully in the destination account:${NC} ${CREATED_AMI}"

# Copy AMI Tags if requested
if [[ "${TAG_OPT}" == "y" ]]; then
    AMI_TAGS=$(echo "${AMI_DETAILS}" | jq -c '.Tags')
    if [[ "${AMI_TAGS}" != "null" ]]; then
        aws ec2 create-tags --resources "${CREATED_AMI}" --tags "$(echo "${AMI_TAGS}" | jq -c '.[]')" --profile "${DST_PROFILE}" --region "${DST_REGION}" || die "Unable to add tags to the AMI in the destination account. Aborting."
        echo -e "${COLOR}Tags copied for AMI:${NC} ${CREATED_AMI}"

        if [[ -n "${UPSERT_TAG_OPT}" ]]; then
            IFS=':' read -r TAG_KEY TAG_VALUE <<< "${UPSERT_TAG_OPT}"
            if [[ -n "${TAG_KEY}" && -n "${TAG_VALUE}" ]]; then
                aws ec2 create-tags --resources "${CREATED_AMI}" --tags Key="${TAG_KEY}",Value="${TAG_VALUE}" --profile "${DST_PROFILE}" --region "${DST_REGION}" || die "Unable to add/update tag '${TAG_KEY}:${TAG_VALUE}' to AMI ${CREATED_AMI} in the destination account. Aborting."
                echo -e "${COLOR}Tag '${TAG_KEY}:${TAG_VALUE}' added to AMI:${NC} ${CREATED_AMI}"
            else
                echo -e "${RED}Invalid UPSERT_TAG_OPT format. Expected key:value. Bypassing...${NC}"
            fi
        fi
    else
        echo -e "${COLOR}No tags found for AMI:${NC} ${AMI_ID}"
    fi
fi