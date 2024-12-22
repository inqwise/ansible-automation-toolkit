# GoldenImage Automation Toolkit Documentation

Welcome to the **GoldenImage Automation Toolkit** documentation. This toolkit is designed to streamline the creation and management of Amazon Machine Images (AMIs) using Packer and custom Bash scripts. The toolkit comprises three primary components:

1. **`goldenimage.sh`**: A Bash script for setting up the environment, installing dependencies, downloading playbooks, and executing the main provisioning script.
2. **`goldenimage.pkr.hcl`**: A Packer configuration file defining the build process for creating AMIs.
3. **`goldenimage-postprocess.sh`**: A Bash script for processing the Packer-generated manifest, extracting relevant information, and performing cleanup tasks.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Scripts](#scripts)
  - [`goldenimage.sh`](#goldenimagesh)
    - [Purpose](#purpose)
    - [Usage](#usage)
    - [Arguments](#arguments)
    - [Environment Variables](#environment-variables)
    - [Functionality](#functionality)
    - [Error Handling](#error-handling)
  - [`goldenimage.pkr.hcl`](#goldenimagepkrhcl)
    - [Purpose](#purpose-1)
    - [Configuration Details](#configuration-details)
      - [Variables](#variables)
      - [Data Sources](#data-sources)
      - [Locals](#locals)
      - [Source Block](#source-block)
      - [Build Block](#build-block)
    - [Provisioners](#provisioners)
    - [Post-Processors](#post-processors)
  - [`goldenimage-postprocess.sh`](#goldenimage-postprocesssh)
    - [Purpose](#purpose-2)
    - [Usage](#usage-1)
    - [Functionality](#functionality-1)
    - [Error Handling](#error-handling-1)
- [Workflow](#workflow)
- [Setup Instructions](#setup-instructions)
- [Troubleshooting](#troubleshooting)
- [Security Considerations](#security-considerations)
- [Support](#support)

---

## Overview

The GoldenImage Automation Toolkit automates the process of creating and managing AMIs tailored to your application's requirements. It leverages Packer for image creation and custom Bash scripts for environment setup, playbook execution, and post-processing tasks. This toolkit ensures consistency, repeatability, and efficiency in your infrastructure provisioning workflows.

---

## Prerequisites

Before using the GoldenImage Automation Toolkit, ensure you have the following:

- **Operating System**: Unix-based system (Linux, macOS)
- **Tools & Software**:
  - [Packer](https://www.packer.io/) (version compatible with the configuration)
  - [AWS CLI](https://aws.amazon.com/cli/) configured with necessary permissions
  - [jq](https://stedolan.github.io/jq/) for JSON processing
  - `bash` shell
  - `curl` and `wget` for downloading scripts
- **AWS Credentials**: Properly configured AWS credentials with permissions to create AMIs, access S3, Secrets Manager, and Parameter Store.

---

## Scripts

### `goldenimage.sh`

#### Purpose

`goldenimage.sh` is a Bash script responsible for setting up the environment, installing necessary dependencies, downloading Ansible playbooks, and executing the main provisioning script. It ensures that the system is correctly configured before initiating the AMI build process.

#### Usage

```bash
./goldenimage.sh -r <region> --playbook_name <name> --playbook_base_url <url> --vault_password <password> [options]
```

#### Arguments

##### Mandatory Arguments

- `-r <region>`: Specifies the AWS region.
- `--playbook_name <name>`: Name of the Ansible playbook to execute.
- `--playbook_base_url <url>`: Base URL where the playbooks are hosted.
- `--vault_password <password>`: Vault password for securing sensitive data.

##### Optional Arguments

- `--environment-id <id>`: Specifies the environment ID.
- `--token <token>`: Token for authentication or API access.
- `--get_pip_url <url>`: URL to download `get-pip.py`.
- `--account_id <id>`: AWS account ID.
- `--topic_name <name>`: Name of the topic (e.g., SNS topic).
- `--playbook_version <version>`: Version of the playbook to use.
- `--toolkit_version <version>`: Version of the automation toolkit.
- `--verbose`: Enables verbose mode for detailed logging.
- `--skip-remote-requirements`: Skips downloading remote requirements.

#### Environment Variables

The script supports several environment variables that can override default values:

- `TOOLKIT_VERSION`: Version of the automation toolkit.
- `VAULT_PASSWORD_FILE`: File path for storing the vault password.
- `PIP_COMMAND`: Command to invoke `pip`.
- `GET_PIP_URL`: URL to download `get-pip.py`.
- `PLAYBOOK_VERSION`: Version of the playbook.
- `REGION`: AWS region.
- `PLAYBOOK_NAME`: Name of the playbook.
- `PLAYBOOK_BASE_URL`: Base URL for playbooks.
- `VAULT_PASSWORD`: Vault password.
- `VERBOSE`: Enables verbose mode.
- `SKIP_REMOTE_REQUIREMENTS`: Skips remote requirements download.
- `ENVIRONMENT_ID`: Environment ID.

#### Functionality

1. **Argument Parsing**: Utilizes `getopts` to parse both short (`-r`) and long (`--`) options.
2. **Validation**: Ensures all mandatory arguments are provided; exits with usage instructions if not.
3. **Verbose Mode**: Enables shell debugging if `--verbose` is set.
4. **OS Identification**: Determines the operating system either locally or by downloading a remote script.
5. **Environment Setup**:
   - Creates and configures the `/deployment` directory.
   - Sets up a Python virtual environment.
6. **Dependency Installation**: Installs `pip` using the specified URL.
7. **Playbook Download**: Downloads the specified playbook from S3.
8. **Main Script Execution**: Runs the `main.sh` script with appropriate arguments.
9. **Cleanup**: Removes sensitive files like `vault_password`.

#### Error Handling

- Checks for the existence of mandatory variables and files.
- Provides meaningful error messages and usage instructions upon encountering issues.
- Implements `set -euo pipefail` for robust error detection.
- Captures and logs errors during execution for easier troubleshooting.

---

### `goldenimage.pkr.hcl`

#### Purpose

`goldenimage.pkr.hcl` is the Packer configuration file that defines how AMIs are built for different architectures and regions. It specifies variables, data sources, build sources, provisioning steps, and post-processing actions to create standardized and secure AMIs for deployment.

#### Configuration Details

##### Variables

Defines configurable parameters for the Packer build process:

- **`cpu_arch`**: CPU architecture type (`arm64` or `x86`).
- **`instance_type`**: AWS EC2 instance type.
- **`base_path`**: S3 base path for playbooks.
- **`tag`**: Version tag for the image.
- **`aws_region`**: AWS region for building the AMI.
- **`aws_run_region`**: AWS region where the build runs.
- **`aws_iam_instance_profile`**: IAM instance profile for Packer.
- **`aws_profile`**: AWS CLI profile to use.
- **`app`**: Application name (e.g., `consul`).
- **`toolkit_version`**: Version of the automation toolkit.
- **`verbose`**: Enables verbose logging.
- **`skip_remote_requirements`**: Skips downloading remote requirements.
- **`environment_id`**: Environment identifier.
- **`kms_key_id`**: KMS key ID for encrypting the root EBS volume.
- **`encrypted`**: Flag to encrypt the root EBS volume (`true`, `false`, or empty).

##### Data Sources

Utilizes AWS data sources to fetch secrets and parameters:

- **`amazon-secretsmanager.vault_secret`**: Retrieves the vault secret from AWS Secrets Manager.
- **`amazon-parameterstore.UserDataYAMLConfig`**: Retrieves user data configuration from AWS Parameter Store.

##### Locals

Defines local variables for internal computations and configurations:

- **`user_data_config`**: Decoded YAML configuration from Parameter Store.
- **`environment_id`**: Determines the environment ID based on precedence.
- **`kms_key_id`**: Determines the KMS key ID based on precedence.
- **`aws_run_region`**: Determines the run region based on precedence.
- **`ami_regions`, `share_accounts`, `ami_accounts`, `snapshot_accounts`**: Configures regions and accounts for AMI sharing.
- **`playbook_base_url`**: Determines the base URL for playbooks based on precedence.
- **`instance_types`**: Maps CPU architectures to default instance types.
- **`playbook_name`**: Constructs the playbook name based on the application.
- **`common_build_settings`**: Configures shell provisioners and post-processors.
- **`timestamp`**: Generates a timestamp for AMI naming.

##### Source Block

Defines the AMI source configuration using the `amazon-ebs` builder:

- **`force_deregister`**: Automatically deregisters AMIs if they already exist.
- **`force_delete_snapshot`**: Deletes associated snapshots when AMIs are deregistered.
- **`ami_name`**: Names the AMI using the application name and tag.
- **`ami_description`**: Describes the AMI with details like version and timestamp.
- **`spot_instance_types`**: Specifies spot instance types based on CPU architecture.
- **`region`**: AWS region for building the AMI.
- **`ami_regions`, `ami_users`, `snapshot_users`**: Configures sharing of the AMI across regions and accounts.
- **`encrypt_boot`**: Disables boot volume encryption (managed via KMS key).
- **`profile`**: AWS CLI profile to use.
- **`iam_instance_profile`**: IAM role for Packer.
- **`ssh_username`**: SSH user for provisioning.
- **`spot_price`**: Spot instance pricing strategy.
- **`metadata_options`**: Configures instance metadata service options.
- **`run_tags` and `tags`**: Tags for the build and the resulting AMI.
- **`launch_block_device_mappings`**: Dynamically adds block device mappings if `kms_key_id` is provided.

##### Build Block

Defines the build process using multiple sources and provisioners:

- **Sources**:
  - `amzn2023_arm64`: Builds an AMI for Amazon Linux 2023 ARM64 architecture.
  - `amzn2_x86`: Builds an AMI for Amazon Linux 2 x86 architecture.

- **Provisioners**:
  - **Shell Provisioner**: Executes inline commands or scripts to set up the AMI. It includes downloading the `goldenimage.sh` script and executing it with the necessary environment variables.

- **Post-Processors**:
  - **Manifest**: Generates a `manifest.json` file containing build details.
  - **Shell-Local**: Executes a local post-processing script (`goldenimage-postprocess.sh`) either from a local file or by downloading it remotely.

#### Provisioners

- **Shell Provisioners**: Execute shell commands or scripts during the build process to install dependencies, configure the system, and run Ansible playbooks.
- **Inline Scripts**: Commands are executed directly within the Packer build environment.
- **Script Files**: External scripts are sourced and executed.

#### Post-Processors

- **Manifest**: Creates a `manifest.json` file that records details of the AMI build, such as AMI IDs, build time, and custom data.
- **Shell-Local**: Runs the `goldenimage-postprocess.sh` script to process the manifest and perform cleanup tasks.

---

### `goldenimage-postprocess.sh`

#### Purpose

`goldenimage-postprocess.sh` is a Bash script designed to process the `manifest.json` file generated by Packer. It extracts relevant information about the last AMI build, compiles it into a result file (`goldenimage_result.json`), and performs cleanup tasks such as removing local Packer configuration files.

#### Usage

```bash
./goldenimage-postprocess.sh
```

#### Functionality

1. **Validation**:
   - Checks for the existence of `manifest.json`.
   - Verifies the presence of `last_run_uuid` within the manifest.

2. **Data Extraction**:
   - Uses `jq` to parse `manifest.json` and locate the build entry matching `last_run_uuid`.
   - Extracts fields such as `timestamp`, `all_amis`, `app`, `profile`, `region`, `run_region`, and `version`.

3. **Result Compilation**:
   - Constructs a `result_object` containing the extracted fields.
   - Adds the specific AMI ID corresponding to the `run_region`.

4. **Output**:
   - Saves the `result_object` to `goldenimage_result.json`.

5. **Variable Extraction**:
   - Extracts values like `template_name`, `new_ami_id`, `version_description`, `aws_profile`, and `aws_region` from the `result_object` for use in subsequent operations.

6. **Cleanup**:
   - Removes the local Packer configuration file (`goldenimage.pkr.hcl`) if it exists.

#### Error Handling

- **Missing Files**: Exits with an error message if `manifest.json` is not found.
- **Missing Fields**: Exits with an error if `last_run_uuid` or the matching build object is not found.
- **Parsing Errors**: Ensures that the `result_object` contains the required fields; exits with an error if parsing fails.
- **Cleanup Failures**: Logs messages upon successful removal of files; errors during removal are handled gracefully.

---

## Workflow

The GoldenImage Automation Toolkit operates in the following sequence:

1. **Environment Setup (`goldenimage.sh`)**:
   - Parses input arguments and validates mandatory parameters.
   - Identifies the operating system.
   - Sets up the deployment environment and Python virtual environment.
   - Installs `pip` and other dependencies.
   - Downloads the specified Ansible playbook from S3.
   - Executes the main provisioning script (`main.sh`) to configure the system.

2. **AMI Build Configuration (`goldenimage.pkr.hcl`)**:
   - Defines variables and configurations for building AMIs.
   - Specifies data sources for secrets and parameters.
   - Sets up local variables for environment-specific configurations.
   - Configures Packer sources for different architectures and regions.
   - Defines provisioning steps using shell scripts.
   - Sets up post-processors to generate manifests and execute post-processing scripts.

3. **Post-Processing (`goldenimage-postprocess.sh`)**:
   - Processes the `manifest.json` generated by Packer.
   - Extracts relevant information about the last AMI build.
   - Compiles the extracted data into `goldenimage_result.json`.
   - Cleans up local configuration files to maintain a tidy environment.

4. **Integration**:
   - The `manifest.json` and `goldenimage_result.json` files serve as artifacts for further automation, such as updating infrastructure templates or triggering deployment pipelines.

---

## Setup Instructions

Follow these steps to set up and use the GoldenImage Automation Toolkit:

### 1. Clone the Repository

```bash
git clone https://github.com/your-repo/goldenimage-toolkit.git
cd goldenimage-toolkit
```

### 2. Install Prerequisites

Ensure all prerequisites are met (see [Prerequisites](#prerequisites)).

### 3. Configure AWS Credentials

Configure your AWS CLI with the necessary credentials and permissions.

```bash
aws configure
```

### 4. Customize Variables

Edit the `goldenimage.pkr.hcl` file to set default values for variables or override them during the Packer build.

### 5. Execute the Build Process

Run the Packer build to create the AMIs.

```bash
packer build goldenimage.pkr.hcl
```

### 6. Post-Processing

After the build completes, `goldenimage-postprocess.sh` will automatically process the manifest and generate `goldenimage_result.json`.

---

## Troubleshooting

### Common Issues

1. **Missing Mandatory Arguments**:
   - **Symptom**: Script exits with usage instructions.
   - **Solution**: Ensure all mandatory arguments (`-r`, `--playbook_name`, `--playbook_base_url`, `--vault_password`) are provided.

2. **AWS Credential Errors**:
   - **Symptom**: AWS CLI commands fail with authentication errors.
   - **Solution**: Verify AWS credentials are correctly configured and have necessary permissions.

3. **Script Download Failures**:
   - **Symptom**: `curl` or `wget` commands fail to download scripts.
   - **Solution**: Check network connectivity and verify URLs are correct and accessible.

4. **Manifest Parsing Errors**:
   - **Symptom**: `goldenimage-postprocess.sh` fails to find `last_run_uuid` or matching build.
   - **Solution**: Ensure `manifest.json` is correctly generated by Packer and contains the expected fields.

5. **Permission Issues**:
   - **Symptom**: Scripts fail due to insufficient permissions.
   - **Solution**: Run scripts with appropriate user privileges or adjust file permissions as needed.

### Debugging Steps

- **Enable Verbose Mode**: Use the `--verbose` flag to get detailed logs.
- **Check Logs**: Review console output and generated log files for error messages.
- **Validate JSON Files**: Use `jq` to validate and inspect `manifest.json` and `goldenimage_result.json`.
- **Test Scripts Independently**: Run each script separately to isolate issues.

---

## Security Considerations

- **Vault Password Management**: Ensure `VAULT_PASSWORD` is securely stored and handled. Avoid hardcoding sensitive information.
- **IAM Roles and Permissions**: Assign the least privilege principle to IAM roles used by Packer and scripts.
- **Encrypted Volumes**: Utilize KMS keys (`kms_key_id`) to encrypt EBS volumes for enhanced security.
- **Secure S3 Buckets**: Restrict access to S3 buckets storing playbooks and artifacts.
- **Network Security**: Configure security groups and network ACLs to limit access to deployed instances.

---

*© 2024 Your Company Name. All rights reserved.*