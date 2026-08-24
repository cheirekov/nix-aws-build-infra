# Reproducibility model

This repository aims for repeatable infrastructure and auditable inputs, but it
does not claim byte-identical AMIs.

## Pinned or locked inputs

- `flake.lock` fixes Nixpkgs.
- `.terraform.lock.hcl` fixes OpenTofu provider selections and checksums.
- the Packer Amazon plugin has an exact required version.
- Nix, GitHub Actions runner and runner archive SHA-256 values are explicit in
  `packer/runner.pkr.hcl`.
- third-party Actions are pinned to full commit SHAs.
- deployment-specific IDs and keys are explicit ignored inputs rather than
  hidden source-code constants.
- OpenTofu apply consumes a saved plan, separating review from mutation.

## Intentionally refreshed inputs

Packer selects the latest official Canonical Ubuntu 24.04 AMI for each
architecture. Provisioning installs current OS security updates and current AWS
SSM/CloudWatch components. Therefore two builds on different days may have
different package and base-image contents even when application versions are
unchanged.

This is an operational-image policy: rebuild monthly and after relevant
security advisories, validate the fixture, keep the latest two images, and
record the resulting AMI IDs in SSM. It avoids silently running an indefinitely
old OS image while remaining auditable through Packer logs and AMI metadata.

For byte-identical images, a separate project would need content-addressed base
images, snapshot repositories for every package source, deterministic image
assembly and provenance signing. That is outside this platform's current
security and maintenance model.

## What a new user must supply

A deployment requires its own GitHub owner/repository IDs, AWS account and SSO
roles, state/cache buckets, signing keys, notification target and App
installation. `scripts/init-deployment.sh` discovers/generates these values
without editing generic source code. Safe public endpoints and public keys may
be published under an explicitly named `deployments/` reference.
