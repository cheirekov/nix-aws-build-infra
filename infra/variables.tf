variable "aws_region" {
  description = "AWS region for builders and cache origin."
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Prefix and management tag for all resources."
  type        = string
  default     = "nix-aws-build-infra"

  validation {
    condition     = length(var.project_name) >= 3 && length(var.project_name) <= 24 && can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-24 lowercase letters, digits or hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "github_owner" {
  description = "GitHub user or organization that owns the infrastructure and build repositories."
  type        = string
}

variable "github_owner_id" {
  description = "Immutable GitHub owner ID used in immutable OIDC subjects."
  type        = number
}

variable "infra_repository_name" {
  description = "Repository containing this infrastructure and the AMI workflow."
  type        = string
  default     = "nix-aws-build-infra"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+$", var.infra_repository_name))
    error_message = "infra_repository_name must be a GitHub repository name, not owner/name."
  }
}

variable "github_environment" {
  type    = string
  default = "aws-build"
}

variable "allowed_repositories" {
  description = "Repository names and immutable IDs allowed to assume the provisioning role."
  type        = map(number)

  validation {
    condition     = contains(keys(var.allowed_repositories), var.infra_repository_name)
    error_message = "allowed_repositories must include infra_repository_name."
  }
}

variable "cache_key_name" {
  type    = string
  default = "nix-aws-build-infra-1"
}

variable "local_cache_key_name" {
  description = "Name embedded in cache paths signed explicitly by a local operator."
  type        = string
  default     = "nix-aws-local-1"
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

variable "local_cache_public_key" {
  description = "Public half of the isolated local cache publisher key. Empty means rollout is pending."
  type        = string
  default     = ""
  sensitive   = false

  validation {
    condition     = var.local_cache_public_key == "" || can(regex("^[^:]+:[A-Za-z0-9+/=]+$", var.local_cache_public_key))
    error_message = "Generate the local publisher key with scripts/generate-signing-key.sh local."
  }
}

variable "standard_runner_root_volume_gb" {
  type    = number
  default = 150
}

variable "standard_runner_root_volume_iops" {
  type    = number
  default = 3000
}

variable "standard_runner_root_volume_throughput" {
  type    = number
  default = 125
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

variable "watchdog_keep_amis_per_architecture" {
  description = "Number of Packer AMIs and snapshots retained for each architecture."
  type        = number
  default     = 2
}

variable "monthly_budget_usd" {
  description = "Soft monthly cost ceiling for tagged build infrastructure."
  type        = number
  default     = 25
}

variable "budget_notification_email" {
  description = "Optional private rollout value for AWS Budget email notifications."
  type        = string
  default     = ""
}

variable "cache_size_alarm_bytes" {
  description = "Alert threshold for the append-only binary cache."
  type        = number
  default     = 107374182400
}
