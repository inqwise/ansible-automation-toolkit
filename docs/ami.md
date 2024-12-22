# AWS AMI Management Scripts

A comprehensive suite of Bash scripts designed to manage Amazon Machine Images (AMIs) within AWS environments. This suite facilitates tasks such as assigning AMIs to templates, cleaning up test AMIs, copying shared AMIs across regions, deregistering AMIs and their associated snapshots, and tagging snapshots for better organization and tracking.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Scripts Overview](#scripts-overview)
  - [1. assign_ami_to_template_bulk.sh](#1-assign_ami_to_template_bulksh)
  - [2. cleanup_test_amis.sh](#2-cleanup_test_amissh)
  - [3. copy_shared_amis.sh](#3-copy_shared_amissh)
  - [4. deregister_ami.sh](#4-deregister_amish)
  - [5. deregister_old_ami_by_app.sh](#5-deregister_old_ami_by_appsh)
  - [6. tag_assigned_snapshot.sh](#6-tag_assigned_snapshotsh)
- [General Best Practices](#general-best-practices)
- [Support](#support)

---

## Prerequisites

Before utilizing these scripts, ensure the following prerequisites are met:

- **AWS CLI**: Installed and configured with appropriate permissions.
- **jq**: A lightweight and flexible command-line JSON processor.
- **curl or wget**: For downloading auxiliary scripts when necessary.
- **Bash Shell**: These scripts are written for Bash and have been tested on Bash version 4 and above.
- **AWS IAM Permissions**: The AWS CLI profile used must have permissions to perform EC2 actions such as `describe-images`, `deregister-image`, `delete-snapshot`, `create-tags`, etc.

---

## Scripts Overview

### 1. assign_ami_to_template_bulk.sh

**Filename**: `assign_ami_to_template_bulk.sh`

**Description**:  
Assigns multiple AMIs to their respective templates based on specified criteria. It fetches AMIs with specific tags and states, processes and groups them by template name, downloads an external `update_template_ami.sh` script if not present, and assigns AMIs to templates based on versioning and prioritization.

**Usage**:
```bash
./assign_ami_to_template_bulk.sh --region <region> [--profile <profile>] [--toolkit-version <version>] [--make-default-version] [--create-template-if-not-exist] [--skip-template-if-not-exist]
```

**Options**:

- `--region <region>`  
  **Description**: AWS region to search for AMIs.  
  **Required**: Yes

- `--profile <profile>`  
  **Description**: AWS CLI profile to use.  
  **Required**: No

- `--toolkit-version <version>`  
  **Description**: Version of the toolkit to use.  
  **Default**: `default`

- `--make-default-version`  
  **Description**: Flag to set the AMI as the default version.  
  **Default**: `false`  
  **Type**: Boolean Flag

- `--create-template-if-not-exist`  
  **Description**: Create the template if it does not exist.  
  **Default**: `false`  
  **Type**: Boolean Flag

- `--skip-template-if-not-exist`  
  **Description**: Skip processing if the template does not exist.  
  **Default**: `false`  
  **Type**: Boolean Flag

**Examples**:

1. **Assign AMIs in the `us-east-1` region with default settings**:
   ```bash
   ./assign_ami_to_template_bulk.sh --region us-east-1
   ```

2. **Assign AMIs using a specific AWS profile and toolkit version**:
   ```bash
   ./assign_ami_to_template_bulk.sh --region us-west-2 --profile my-profile --toolkit-version v1.2.3
   ```

3. **Assign AMIs and set them as the default version**:
   ```bash
   ./assign_ami_to_template_bulk.sh --region eu-central-1 --make-default-version
   ```

4. **Create the template if it does not exist**:
   ```bash
   ./assign_ami_to_template_bulk.sh --region ap-southeast-1 --create-template-if-not-exist
   ```

**Dependencies**:

- `aws` CLI
- `jq`
- `curl`

**Notes**:

- The script downloads the `update_template_ami.sh` script from the specified toolkit version if it's not found locally.
- Mutual exclusivity is enforced between `--create-template-if-not-exist` and `--skip-template-if-not-exist`.
- Ensure that the AWS CLI profile provided has the necessary permissions to describe and update AMIs and templates.

---

### 2. cleanup_test_amis.sh

**Filename**: `cleanup_test_amis.sh`

**Description**:  
Cleans up test AMIs by searching for AMIs containing `-test` in their name that were created by the user and deregistering them. Supports a dry-run mode to preview actions without executing them.

**Usage**:
```bash
./cleanup_test_amis.sh [--profile <aws_profile>] [--region <aws_region>] [--dry-run] [--help]
```

**Options**:

- `--profile <aws_profile>`  
  **Description**: Use the specified AWS CLI profile.  
  **Required**: No

- `--region <aws_region>`  
  **Description**: Specify the AWS region.  
  **Required**: No

- `--dry-run`  
  **Description**: Show which AMIs would be deregistered without performing the action.  
  **Default**: `false`  
  **Type**: Boolean Flag

- `--help`  
  **Description**: Display the help message and exit.  
  **Required**: No

**Examples**:

1. **Deregister test AMIs in the `us-east-1` region using the default profile**:
   ```bash
   ./cleanup_test_amis.sh --region us-east-1
   ```

2. **Perform a dry run to see which AMIs would be deregistered**:
   ```bash
   ./cleanup_test_amis.sh --region us-east-1 --dry-run
   ```

3. **Use a specific AWS profile and region**:
   ```bash
   ./cleanup_test_amis.sh --profile my-profile --region eu-west-2
   ```

**Dependencies**:

- `aws` CLI
- `jq`
- `curl`

**Notes**:

- The script downloads the `deregister_ami.sh` helper script if it is not found locally.
- In dry-run mode, the script lists the AMIs that would be deregistered without making any changes.
- Ensure that the AWS CLI profile provided has the necessary permissions to describe and deregister AMIs.

---

### 3. copy_shared_amis.sh

**Filename**: `copy_shared_amis.sh`

**Description**:  
Copies AMIs from a source region to a target region, ensuring that no duplicate AMIs exist in the target region. Handles tagging, supports encryption using a specified KMS Key ID, and maintains a JSON log of newly copied AMIs. It also manages existing AMIs in the target region by deregistering them if necessary.

**Usage**:
```bash
./copy_shared_amis.sh --source-region <SOURCE_REGION> --region <TARGET_REGION> [--source-account-id <SOURCE_ACCOUNT_ID>] [--profile <PROFILE>] [--limit <LIMIT>] [--source-kms-key-id <KMS_KEY_ID>] [--toolkit-version <TOOLKIT_VERSION>]
```

**Options**:

- `--source-region <SOURCE_REGION>`  
  **Description**: AWS region where the source AMIs are located.  
  **Required**: Yes

- `--region <TARGET_REGION>`  
  **Description**: AWS region where AMIs will be copied to.  
  **Required**: Yes

- `--source-account-id <SOURCE_ACCOUNT_ID>`  
  **Description**: AWS Account ID of the source AMIs.  
  **Default**: Current AWS account ID

- `--profile <PROFILE>`  
  **Description**: AWS CLI profile to use.  
  **Required**: No

- `--limit <LIMIT>`  
  **Description**: Limit the number of source AMIs to copy.  
  **Default**: `0` (No limit)

- `--source-kms-key-id <KMS_KEY_ID>`  
  **Description**: KMS Key ID for encrypting the copied AMIs.  
  **Required**: No

- `--toolkit-version <TOOLKIT_VERSION>`  
  **Description**: Version of the toolkit to use for downloading helper scripts.  
  **Default**: `default`

**Examples**:

1. **Copy all AMIs from `us-west-1` to `us-east-1` using the default profile**:
   ```bash
   ./copy_shared_amis.sh --source-region us-west-1 --region us-east-1
   ```

2. **Copy AMIs with a limit of 5 AMIs using a specific AWS profile**:
   ```bash
   ./copy_shared_amis.sh --source-region us-west-2 --region eu-central-1 --profile my-profile --limit 5
   ```

3. **Copy AMIs with encryption using a specific KMS Key ID**:
   ```bash
   ./copy_shared_amis.sh --source-region ap-southeast-1 --region eu-west-3 --source-kms-key-id arn:aws:kms:us-east-1:123456789012:key/abcd-efgh-ijkl-mnop
   ```

**Dependencies**:

- `aws` CLI
- `jq`
- `curl`

**Notes**:

- The script downloads the `deregister_ami.sh` helper script if it is not found locally.
- It maintains a JSON log of newly copied AMIs at `new_amis.json` in the script's directory.
- Ensure that the AWS CLI profile provided has the necessary permissions to describe, copy, and tag AMIs, as well as deregister existing AMIs if necessary.

---

### 4. deregister_ami.sh

**Filename**: `deregister_ami.sh`

**Description**:  
A helper script that deregisters a specified AMI and deletes all associated snapshots. It supports a dry-run mode to preview actions without executing them.

**Usage**:
```bash
./deregister_ami.sh --ami <ami-id> --region <region> [--profile <profile>] [--dry-run]
```

**Options**:

- `--ami <ami-id>`  
  **Description**: The AMI ID to deregister.  
  **Required**: Yes

- `--region <region>`  
  **Description**: AWS region where the AMI resides.  
  **Required**: Yes

- `--profile <profile>`  
  **Description**: AWS CLI profile to use.  
  **Required**: No

- `--dry-run`  
  **Description**: Show actions without executing them.  
  **Default**: `false`  
  **Type**: Boolean Flag

- `-h, --help`  
  **Description**: Display the help message and exit.  
  **Required**: No

**Examples**:

1. **Deregister an AMI in the `us-east-1` region**:
   ```bash
   ./deregister_ami.sh --ami ami-0abcdef1234567890 --region us-east-1
   ```

2. **Perform a dry run to see which actions would be taken**:
   ```bash
   ./deregister_ami.sh --ami ami-0abcdef1234567890 --region us-east-1 --dry-run
   ```

3. **Use a specific AWS profile**:
   ```bash
   ./deregister_ami.sh --ami ami-0abcdef1234567890 --region eu-west-2 --profile my-profile
   ```

**Dependencies**:

- `aws` CLI

**Notes**:

- The script deletes all snapshots associated with the specified AMI after deregistering it.
- In dry-run mode, it will only display the actions without performing any deletions.
- Ensure that the AWS CLI profile provided has the necessary permissions to deregister AMIs and delete snapshots.

---

### 5. deregister_old_ami_by_app.sh

**Filename**: `deregister_old_ami_by_app.sh`

**Description**:  
Cleans up old AMIs based on retention policies by grouping AMIs by application and retaining a specified number of recent versions. It supports limiting the number of applications to process and utilizes the `deregister_ami.sh` helper script for deregistering AMIs.

**Usage**:
```bash
./deregister_old_ami_by_app.sh --region <region> [--profile <profile>] [--keep-history <number>] [--limit <number>]
```

**Options**:

- `--region <region>`  
  **Description**: AWS region to search for AMIs.  
  **Required**: Yes

- `--profile <profile>`  
  **Description**: AWS CLI profile to use.  
  **Required**: No

- `--keep-history <number>`  
  **Description**: Number of recent AMI versions to retain per application.  
  **Default**: `3`

- `--limit <number>`  
  **Description**: Limit the number of applications to process.  
  **Default**: `0` (No limit)

**Examples**:

1. **Deregister old AMIs in the `us-east-1` region, keeping the latest 3 versions per app**:
   ```bash
   ./deregister_old_ami_by_app.sh --region us-east-1
   ```

2. **Deregister old AMIs using a specific AWS profile and keep the latest 5 versions**:
   ```bash
   ./deregister_old_ami_by_app.sh --region eu-central-1 --profile my-profile --keep-history 5
   ```

3. **Deregister old AMIs for a limited number of applications**:
   ```bash
   ./deregister_old_ami_by_app.sh --region ap-southeast-1 --limit 2
   ```

**Dependencies**:

- `aws` CLI
- `jq`
- `curl`

**Notes**:

- The script downloads the `deregister_ami.sh` helper script if it is not found locally.
- It ensures that the AWS CLI profile provided is valid before proceeding.
- Detailed logs are provided to track the actions taken during the deregistration process.
- Ensure that the AWS CLI profile provided has the necessary permissions to describe and deregister AMIs.

---

### 6. tag_assigned_snapshot.sh

**Filename**: `tag_assigned_snapshot.sh`

**Description**:  
Tags snapshots associated with AMIs based on specific tag criteria. It filters AMIs and their snapshots, copies relevant tags from AMIs to their associated snapshots, skips tagging if snapshots already have tags or if AMIs lack relevant tags, and updates AMIs with tagging status to indicate whether snapshots were tagged or skipped.

**Usage**:
```bash
./tag_assigned_snapshot.sh --region <region> [--profile <profile>]
```

**Options**:

- `--region <region>`  
  **Description**: AWS region to search for AMIs and snapshots.  
  **Required**: Yes

- `--profile <profile>`  
  **Description**: AWS CLI profile to use.  
  **Required**: No

**Examples**:

1. **Tag snapshots in the `us-east-1` region using the default profile**:
   ```bash
   ./tag_assigned_snapshot.sh --region us-east-1
   ```

2. **Tag snapshots using a specific AWS profile**:
   ```bash
   ./tag_assigned_snapshot.sh --region eu-west-2 --profile my-profile
   ```

**Dependencies**:

- `aws` CLI
- `jq`

**Notes**:

- The script copies specific tags (`Name`, `app`, `version`, `timestamp`, `amm:source_region`, `amm:source_account`, `amm:source_ami`) from AMIs to their associated snapshots.
- It skips tagging for snapshots that already have tags or for AMIs that do not possess relevant tags.
- After processing, the script updates each AMI with a `amm:snapshot_tagging_status` tag indicating whether snapshots were tagged (`changed`) or skipped (`skipped`).
- Ensure that the AWS CLI profile provided has the necessary permissions to describe and tag AMIs and snapshots.

---

## General Best Practices

To ensure the smooth and secure operation of these scripts, adhere to the following best practices:

1. **Secure AWS Credentials**:
   - Use IAM roles and least privilege principles.
   - Avoid hardcoding AWS credentials. Instead, leverage AWS CLI profiles or environment variables.

2. **Logging and Monitoring**:
   - Implement logging mechanisms to track script executions and actions taken.
   - Monitor AWS CloudTrail logs for auditing purposes.

3. **Error Handling**:
   - Ensure scripts handle errors gracefully and provide meaningful error messages.
   - Utilize exit codes appropriately to indicate success or failure.

4. **Testing**:
   - Test scripts in a non-production environment before deploying them in production.
   - Utilize the `--dry-run` option where available to preview actions without making changes.

5. **Version Control**:
   - Maintain scripts in a version-controlled repository (e.g., Git) to track changes and facilitate collaboration.

6. **Documentation**:
   - Keep documentation up-to-date with any changes to the scripts.
   - Provide clear instructions and examples to aid users in understanding script functionalities.

7. **Scheduling and Automation**:
   - Use AWS services like Lambda or external tools like cron to schedule regular executions of these scripts as needed.

8. **Resource Cleanup**:
   - Ensure that scripts do not leave orphaned resources, such as untagged snapshots, which can lead to increased costs.

---

## Support

For any issues, questions, or contributions related to these scripts, please follow the standard support and contribution guidelines of your organization or repository. Ensure that any modifications adhere to the security and operational standards in place.

---

*Happy AMI Managing! 🚀*
```

---
