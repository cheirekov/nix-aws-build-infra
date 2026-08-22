variable "aws_region" {
  description = "AWS region for builders and cache origin."
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Prefix and management tag for all resources."
  type        = string
  default     = "nix-aws-build-infra"
}

variable "github_owner" {
  type    = string
  default = "cheirekov"
}

variable "github_owner_id" {
  description = "Immutable GitHub owner ID used in the default OIDC subject for new repositories."
  type        = number
  default     = 16937955
}

variable "github_environment" {
  type    = string
  default = "aws-build"
}

variable "allowed_repositories" {
  description = "Repository names and immutable IDs allowed to assume the provisioning role."
  type        = map(number)
  default = {
    brave_browser_nix   = 1340587597
    nix-aws-build-infra = 1342757814
  }
}

variable "cache_key_name" {
  type    = string
  default = "nix-aws-build-infra-1"
}

variable "cache_public_key" {
  description = "Public Nix cache key. The private half is never managed by OpenTofu."
  type        = string
  sensitive   = false

  validation {
    condition     = can(regex("^[^:]+:[A-Za-z0-9+/=]+$", var.cache_public_key)) && !strcontains(var.cache_public_key, "GENERATE_WITH")
    error_message = "Generate a real cache key with scripts/generate-signing-key.sh."
  }
}

variable "runner_root_volume_gb" {
  type    = number
  default = 350
}

variable "runner_root_volume_iops" {
  type    = number
  default = 6000
}

variable "runner_root_volume_throughput" {
  type    = number
  default = 250
}

variable "watchdog_max_age_hours" {
  type    = number
  default = 12
}
