//-on-error=abort
// packer build --only=amazon-ebs.amzn2023_arm64 -var 'aws_profile=opinion-stg' -var 'tag=latest' -var app=consul -var 'aws_region=il-central-1' .
packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.2" # preferably "~> 1.2.0" for latest patch version
      source = "github.com/hashicorp/amazon"
    }
  }
}

locals {
  instance_types = {
    arm64 = var.instance_type != "" ? var.instance_type : "t4g.small"
    x86   = var.instance_type != "" ? var.instance_type : "t3.small"
  }

  common_build_settings = {
    shell_provisioners = {
        inline = !fileexists("goldenimage-test.sh") ? [
        "curl --connect-timeout 2.37 -m 20 -o /tmp/goldenimage.sh https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/packer/goldenimage.sh && bash /tmp/goldenimage.sh --tags installation",
        ] : [],
        scripts = fileexists("goldenimage-test.sh") ? [
            "goldenimage-test.sh"
        ] : []
    }
    
    post_processors = {
      manifest = {
        type       = "manifest"
        output     = "manifest.json"
        strip_path = true
        custom_data = {
          app       = var.app
          version   = var.tag
          profile   = var.aws_profile
          region    = var.aws_region
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
  ami_description       = "Image of ${var.app} version ${var.tag}"
  spot_instance_types   = ["${local.instance_types[var.cpu_arch]}"]
  region                = "${var.aws_region}"
  #ami_regions           = ["us-west-2"]
  #ami_users             = ["123456789012", "987654321098"]  # List of AWS Account IDs granted launch permissions for the created AMI
  encrypt_boot          = false
  profile               = "${var.aws_profile}"
  iam_instance_profile  = "${var.aws_iam_instance_profile}"
  ssh_username          = "ec2-user"
  spot_price            = "auto"
  skip_create_ami       = false # for debug

  metadata_options {
    instance_metadata_tags = "enabled"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = "1"
    http_tokens                 = "required"
  }

  run_tags = {
    Name      = "${var.app}-${var.tag}-packer"
    app       = "${var.app}"
    version   = "${var.tag}"
    timestamp = "${local.timestamp}"
    playbook_name = "ansible-${var.app}"
  }

  tags = {
    Name      = "${var.app}-${var.tag}"
    app       = "${var.app}"
    version   = "${var.tag}"
    timestamp = "${local.timestamp}"
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
    name = "amzn2_x64"
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
    scripts = local.common_build_settings.shell_provisioners.scripts
    inline = local.common_build_settings.shell_provisioners.inline
  }

  post-processor "manifest" {
    output     = local.common_build_settings.post_processors.manifest.output
    strip_path = local.common_build_settings.post_processors.manifest.strip_path
    custom_data = local.common_build_settings.post_processors.manifest.custom_data
  }

  post-processor "shell-local" {
    inline = [
      "if [ -f ./goldenimage-postprocess-test.sh ]; then",
      "    echo 'Executing local script: goldenimage-postprocess-test.sh';",
      "    bash ./goldenimage-postprocess-test.sh;",
      "else",
      "    echo 'Local script not found. Executing remote script: https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/packer/goldenimage-postprocess.sh';",
      "    curl -s https://raw.githubusercontent.com/inqwise/ansible-automation-toolkit/default/packer/goldenimage-postprocess.sh | bash;",
      "fi"
    ]
  }
}