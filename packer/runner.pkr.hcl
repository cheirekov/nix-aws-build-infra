packer {
  required_plugins {
    amazon = {
      version = "= 1.3.9"
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

variable "runner_x64_sha256" {
  type    = string
  default = "04cf0be1aff4c3ec3554466c39124ca250e3effd8873bb7e8d68535aa9505d5d"
}

variable "runner_arm64_sha256" {
  type    = string
  default = "58b758e420b87093fbd4bfddd368074960053e2f1388f01848c82624b90f27d1"
}

locals {
  build_timestamp = formatdate("YYYYMMDD-hhmmss", timestamp())
}

source "amazon-ebs" "runner_x86_64" {
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

  ami_name        = "${var.project_name}-x86-64-${local.build_timestamp}"
  ami_description = "Ephemeral x86_64 GitHub and remote Nix builder"
  encrypt_boot    = true

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    ManagedBy    = var.project_name
    Project      = var.project_name
    Purpose      = "github-actions-runner"
    Architecture = "x86_64-linux"
  }
}

source "amazon-ebs" "runner_aarch64" {
  region        = var.aws_region
  instance_type = "t4g.large"
  ssh_username  = "ubuntu"

  temporary_security_group_source_public_ip = true
  ssh_clear_authorized_keys                 = true

  source_ami_filter {
    filters = {
      architecture        = "arm64"
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"]
  }

  ami_name        = "${var.project_name}-aarch64-${local.build_timestamp}"
  ami_description = "Ephemeral aarch64 GitHub and remote Nix builder"
  encrypt_boot    = true

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    ManagedBy    = var.project_name
    Project      = var.project_name
    Purpose      = "github-actions-runner"
    Architecture = "aarch64-linux"
  }
}

build {
  name    = "x86_64-linux"
  sources = ["source.amazon-ebs.runner_x86_64"]

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
      "BUILD_ARCH=x86_64",
      "RUNNER_ARCH=x64",
      "RUNNER_SHA256=${var.runner_x64_sha256}",
      "RUNNER_VERSION=${var.runner_version}",
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}

build {
  name    = "aarch64-linux"
  sources = ["source.amazon-ebs.runner_aarch64"]

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
      "BUILD_ARCH=aarch64",
      "NIX_VERSION=${var.nix_version}",
      "PROJECT_NAME=${var.project_name}",
      "RUNNER_ARCH=arm64",
      "RUNNER_SHA256=${var.runner_arm64_sha256}",
      "RUNNER_VERSION=${var.runner_version}",
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
