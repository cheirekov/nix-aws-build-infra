packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.9, < 2.0.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "eu-central-1"
}

variable "project_name" {
  type    = string
  default = "nix-aws-build-infra"
}

variable "nix_version" {
  type    = string
  default = "2.31.4"
}

variable "runner_version" {
  type    = string
  default = "2.336.0"
}

variable "runner_sha256" {
  type    = string
  default = "04cf0be1aff4c3ec3554466c39124ca250e3effd8873bb7e8d68535aa9505d5d"
}

locals {
  build_timestamp = formatdate("YYYYMMDD-hhmmss", timestamp())
}

source "amazon-ebs" "runner" {
  region        = var.aws_region
  instance_type = "t3.large"
  ssh_username  = "ubuntu"

  temporary_security_group_source_public_ip = true
  ssh_clear_authorized_keys                 = true

  source_ami_filter {
    filters = {
      architecture        = "x86_64"
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"]
  }

  ami_name        = "${var.project_name}-${local.build_timestamp}"
  ami_description = "Ephemeral GitHub Actions Nix builder"
  encrypt_boot    = true

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    ManagedBy = var.project_name
    Project   = var.project_name
    Purpose   = "github-actions-runner"
  }
}

build {
  name    = "nix-aws-runner"
  sources = ["source.amazon-ebs.runner"]

  provisioner "shell" {
    inline = ["mkdir -p /tmp/nix-aws-runtime"]
  }

  provisioner "file" {
    source      = "runtime/"
    destination = "/tmp/nix-aws-runtime/"
  }

  provisioner "shell" {
    script = "scripts/provision.sh"
    environment_vars = [
      "AWS_REGION=${var.aws_region}",
      "NIX_VERSION=${var.nix_version}",
      "PROJECT_NAME=${var.project_name}",
      "RUNNER_SHA256=${var.runner_sha256}",
      "RUNNER_VERSION=${var.runner_version}",
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
