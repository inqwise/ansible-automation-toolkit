packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.2"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "cpu_arch" {
  description = "The CPU architecture type (e.g., arm64 or x86)."
  type        = string
  default     = "arm64"
}

variable "instance_type" {
  type    = string
  default = ""
}

variable "base_path" {
  description = "The S3 base path to playbooks (e.g., s3://bootstrap-opinion-stg/playbooks)."
  type        = string
  default     = ""
}

variable "tag" {
  description = "The version of the image."
  type        = string
}

variable "aws_region" {
  type = string
}

variable "aws_run_region" {
  type = string
  default = ""
}

variable "aws_iam_instance_profile" {
  type    = string
  default = "PackerRole"
}

variable "aws_profile" {
  type    = string
  default = ""
}

variable "app" {
  description = "The app name, for example 'consul'."
  type        = string
}

variable "toolkit_version" {
  description = "Automation toolkit repository release version, for example 'v1'."
  type        = string
  default     = "default"
}

variable "verbose" {
  type    = bool
  default = false
}

variable "skip_remote_requirements" {
  type    = bool
  default = false
}

variable "environment_id" {
  type    = string
  default = ""
}

variable "kms_key_id" {
  description = "The ARN or ID of the KMS key to use for encrypting the root EBS volume."
  type        = string
  default     = ""
}

variable "encrypted" {
  description = "Whether to encrypt the root EBS volume. Acceptable values are 'true', 'false', or ''. An empty string defaults to 'true'."
  type        = string
  default     = ""

  validation {
    condition     = contains(["true", "false", ""], var.encrypted)
    error_message = "The 'encrypted' variable must be either 'true', 'false', or an empty string ''."
  }
}

data "amazon-secretsmanager" "vault_secret" {
  name    = "vault_secret"
  region  = var.aws_region
  profile = var.aws_profile
}

data "amazon-parameterstore" "UserDataYAMLConfig" {
  name            = "UserDataYAMLConfig"
  with_decryption = false
  region          = var.aws_region
  profile         = var.aws_profile
}

locals {
  # Attempt to decode user data; default to empty map if not available
  user_data_config = try(
    yamldecode(data.amazon-parameterstore.UserDataYAMLConfig.value),
    {}
  )

  # Compute environment_id based on precedence
  environment_id = var.environment_id != "" ? var.environment_id : (
    contains(keys(local.user_data_config), "environment_id") ? local.user_data_config.environment_id : ""
  )

  # Compute kms_key_id based on precedence
  kms_key_id = var.kms_key_id != "" ? var.kms_key_id : (
    contains(keys(local.user_data_config), "kms_key_id") ? local.user_data_config.kms_key_id : ""
  )

  aws_run_region = var.aws_run_region != "" ? var.aws_run_region : (
    contains(keys(local.user_data_config), "aws_run_region") ? local.user_data_config.aws_run_region : var.aws_region
  )

  ami_regions = (
    contains(keys(local.user_data_config), "ami_regions") ? local.user_data_config.ami_regions : []
  )

  share_accounts = (
    contains(keys(local.user_data_config), "share_accounts") ? local.user_data_config.share_accounts : []
  )

  ami_accounts = (
    contains(keys(local.user_data_config), "ami_accounts") ? local.user_data_config.ami_accounts : local.share_accounts
  )

  snapshot_accounts = (
    contains(keys(local.user_data_config), "snapshot_accounts") ? local.user_data_config.snapshot_accounts : local.share_accounts
  )

  # Compute playbook_base_url based on precedence
  playbook_base_url = (
    var.base_path != "" ? var.base_path :
    (
      (contains(keys(local.user_data_config), "playbook_base_url") && local.user_data_config.playbook_base_url != "") ? local.user_data_config.playbook_base_url :
      error("Neither var.base_path nor user_data_config.playbook_base_url is provided. Cannot proceed.")
    )
  )

  instance_types = {
    arm64 = var.instance_type != "" ? var.instance_type : "t4g.small"
    x86   = var.instance_type != "" ? var.instance_type : "t3.small"
  }

  playbook_name = "ansible-${var.app}"

  common_build_settings = {
    shell_provisioners = {
      inline = !fileexists("goldenimage-test.sh") ? [
      "curl --connect-timeout 2.37 -m 20 -o /tmp/goldenimage.sh https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/${var.toolkit_version}/packer/goldenimage.sh",
      "bash /tmp/goldenimage.sh",
      ] : [],
      scripts = fileexists("goldenimage-test.sh") ? [
          "goldenimage-test.sh"
      ] : []

      environment_vars = [
        "PLAYBOOK_NAME=${local.playbook_name}",
        "PLAYBOOK_BASE_URL=${local.playbook_base_url}",
        "REGION=${var.aws_region}",
        "VAULT_PASSWORD=${data.amazon-secretsmanager.vault_secret.value}",
        "PLAYBOOK_VERSION=${var.tag}",
        "TOOLKIT_VERSION=${var.toolkit_version}",
        "VERBOSE=${var.verbose}",
        "SKIP_REMOTE_REQUIREMENTS=${var.skip_remote_requirements}",
        "ENVIRONMENT_ID=${local.environment_id}"
      ]
    }
    post_processors = {
      manifest = {
        type       = "manifest"
        output     = "manifest.json"
        strip_path = true
        custom_data = {
          app     = var.app
          version = var.tag
          profile = var.aws_profile
          region  = var.aws_region
        }
      }
    }
  }

  timestamp = formatdate("YYYYMMDDhhmm", timestamp())
}


source "amazon-ebs" "common" {
  force_deregister      = true
  force_delete_snapshot = true
  ami_name              = "${var.app}-${var.tag}"
  ami_description       = "Image of ${var.app} version ${var.tag} timestamp ${local.timestamp}"
  spot_instance_types   = [local.instance_types[var.cpu_arch]]
  region                = local.aws_run_region
  ami_regions           = local.ami_regions
  ami_users             = local.ami_accounts
  snapshot_users        = local.snapshot_accounts
  encrypt_boot          = false
  profile               = var.aws_profile
  iam_instance_profile  = var.aws_iam_instance_profile
  ssh_username          = "ec2-user"
  spot_price            = "auto"
  skip_create_ami       = false # for debug

  metadata_options {
    instance_metadata_tags     = "enabled"
    http_endpoint              = "enabled"
    http_put_response_hop_limit = 1
    http_tokens                = "required"
  }

  run_tags = {
    Name          = "${var.app}-${var.tag}-packer"
    app           = var.app
    version       = var.tag
    timestamp     = local.timestamp
    playbook_name = local.playbook_name
  }

  tags = {
    Name      = "${var.app}-${var.tag}"
    app       = var.app
    version   = var.tag
    timestamp = local.timestamp
  }

  dynamic "launch_block_device_mappings" {
    for_each = (local.kms_key_id != "") ? [1] : []
    content {
      device_name           = "/dev/xvda"
      kms_key_id            = local.kms_key_id
      delete_on_termination = true
    }
  }
}

build {
  source "source.amazon-ebs.common" {
    name = "amzn2023_arm64"
    source_ami_filter {
      filters={
        name                = "al2023-ami-2023.*-kernel-6.1-arm64"
        root-device-type    = "ebs"
        virtualization-type = "hvm"
      }
      most_recent = true 
      owners      = ["amazon"]
    }
  }

  source "source.amazon-ebs.common" {
    name = "amzn2_x86"
    source_ami_filter {
      filters={
        name                = "amzn2-ami-kernel-5.*-x86_64-gp2"
        root-device-type    = "ebs"
        virtualization-type = "hvm"
      }
      most_recent = true 
      owners      = ["amazon"]
    }
  }

  provisioner "shell" {
    scripts          = local.common_build_settings.shell_provisioners.scripts
    inline           = local.common_build_settings.shell_provisioners.inline
    environment_vars = local.common_build_settings.shell_provisioners.environment_vars
  }

  post-processor "manifest" {
    output      = local.common_build_settings.post_processors.manifest.output
    strip_path  = local.common_build_settings.post_processors.manifest.strip_path
    custom_data = local.common_build_settings.post_processors.manifest.custom_data
  }

  post-processor "shell-local" {
    inline = [
      "if [ -f ./goldenimage-postprocess-test.sh ]; then",
      "    echo 'Executing local script: goldenimage-postprocess-test.sh';",
      "    bash ./goldenimage-postprocess-test.sh;",
      "else",
      "    echo 'Local script not found. Executing remote script...';",
      "    curl -s https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/packer/goldenimage-postprocess.sh | bash;",
      "fi"
    ]
  }
}