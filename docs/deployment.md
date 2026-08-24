# NixOS deployment boundary

Remote build execution, cache publication and machine activation are separate
concerns. This repository supplies builders and cache outputs; it does not hold
host credentials or automatically deploy NixOS configurations.

A small fleet can use `deploy-rs` from its configuration flake:

```nix
deploy.nodes.example = {
  hostname = "example.internal";
  profiles.system = {
    user = "root";
    path = deploy-rs.lib.x86_64-linux.activate.nixos
      self.nixosConfigurations.example;
  };
  remoteBuild = false;
  autoRollback = true;
  magicRollback = true;
};
```

`remoteBuild = false` keeps execution explicit: build locally or through an AWS
builder, publish/substitute through CloudFront, then run activation separately.
The target machine must trust the cache public keys and reach the CloudFront
URL.

Build and validate without activation first:

```console
nix-aws session start --system x86_64-linux --profile standard
nix-aws session exec -- nom build .#nixosConfigurations.example.config.system.build.toplevel
nix-aws session stop
nix flake check .
```

Then deploy an unchanged generation during a maintenance window with
independent console access:

```console
deploy .#example
```

Keep the previous deployment method until the pilot host passes deploy checks,
normal activation and a controlled rollback test. This project intentionally
does not implement a package registry, version catalog or FlakeHub-compatible
publishing service.
