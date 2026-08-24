terraform {
  required_version = ">= 1.8.0"

  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70, < 7.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1"
    }
  }

  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      ManagedBy = var.project_name
      Project   = var.project_name
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}
