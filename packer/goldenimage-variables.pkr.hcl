variable "cpu_arch" {
  description = "The CPU architecture type (e.g., arm64 or x86)."
  type        = string
  default     = "arm64"
}

variable "instance_type" {
  type = string
  default = ""
}

variable "base_path" {
  description = "The s3 base path to playbooks (e.g., s3://bootstrap-inqwise-org/playbooks)."
  type = string
  default = "s3://bootstrap-opinion-stg/playbooks"
}

variable "tag" {
  description = "The version of image"
  type    = string
}

variable "aws_region" {
  type    = string
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
  description = "The app name. for example 'consul'"
  type    = string
}