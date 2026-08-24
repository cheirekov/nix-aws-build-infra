# Local and ephemeral builds

Select the deployment and the required named SSO profile before commands that
mutate AWS or publish cache data:

```console
export NIX_AWS_PROFILE=nix-aws-build
export NIX_AWS_REGION=DEPLOYMENT_REGION
export NIX_AWS_PROJECT=DEPLOYMENT_PROJECT_NAME
export NIX_AWS_MONTHLY_BUDGET_USD=DEPLOYMENT_SOFT_BUDGET
aws sso login --profile "$NIX_AWS_PROFILE"
```

The defaults are `nix-aws-build`, `eu-central-1`, and
`nix-aws-build-infra`. Read-only local builds need no AWS session once the
CloudFront substituter and public keys are configured in Nix.

## Local by default

```console
nix-aws build .#package
nix-aws build --push .#package
nix-aws cache push ./result
nix-aws cache push --closure ./result
```

The first command only reads the public CloudFront cache. `build --push` is
explicit and publishes only outputs built by that invocation; upstream
dependencies remain in their existing substituters. It obtains the isolated
`nix-aws-local-1` signing key in a mode-0600 runtime file, verifies every
published output through CloudFront, and removes the key. `cache push` publishes
only the explicitly named paths. Add `--closure` only when a full standalone
mirror of a result and all of its dependencies is required.
Remote builders started by `nix-aws` use the same isolated local signing
identity inside a dedicated EC2 role and publish automatically. GitHub runners
alone use the separate CI signing identity. Their post-build hooks publish only
locally built outputs and retry those outputs at the end of a successful job.

## One-shot remote build

```console
nix-aws build --remote --system x86_64-linux --profile standard .#package
nix-aws build --remote --system aarch64-linux --profile large .#package
```

`standard` provides 16 vCPU, a 150 GB gp3 volume and a four-hour TTL. `large`
provides 32 vCPU, a 350 GB gp3 volume and a ten-hour TTL. The watchdog enforces
an absolute twelve-hour ceiling. There is no On-Demand fallback.

## Reusable session

```console
nix-aws session start --system aarch64-linux --profile standard
nix-aws session exec -- nom build .#nixosConfigurations.oc.config.system.build.toplevel
nix-aws session exec -- nix-build ./legacy-package.nix
nix-aws session status
nix-aws session stop
```

The connection uses an SSM port-forward to SSH with an ephemeral key and a
pinned per-instance host key. No EC2 inbound port is opened. Only one local or
GitHub builder can hold the global lease.

## Monitoring and cost

```console
nix-aws logs list
nix-aws logs tail
nix-aws cost estimate --system aarch64-linux --profile large
nix-aws cost status
```

Build JSONL and terminal logs are stored under
`$XDG_STATE_HOME/nix-aws/logs` and pruned after 30 days. Cost output is an
estimate based on current Spot prices and the selected disk/TTL. The default
monthly soft ceiling is USD 25; override it only after reviewing the estimate.
The recorded monthly figure covers local sessions. AWS Budget notifications,
based on the activated `Project` cost-allocation tag, cover both CI and local
builders but are delayed alerts rather than a hard real-time stop.

## Nix and Home Manager client configuration

After infrastructure apply, render the generated fragment:

```console
./scripts/render-client-config.sh >nix-aws-cache.nix
```

Use its `substituters` and `trusted-public-keys` in system Nix settings. A
standalone Home Manager user cannot change a system Nix daemon's trusted keys
unless the daemon configuration permits it; on NixOS, prefer the system-level
`nix.settings` declaration. Keep `https://cache.nixos.org` as a fallback.
