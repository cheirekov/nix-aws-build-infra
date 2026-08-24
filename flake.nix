{
  description = "Ephemeral EC2 Spot builders and a signed Nix binary cache";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      deploymentNames = builtins.attrNames
        (nixpkgs.lib.filterAttrs (_name: kind: kind == "directory")
          (builtins.readDir ./deployments));
      deploymentReferences = builtins.listToAttrs (map
        (name:
          let reference = builtins.fromJSON (builtins.readFile (./deployments + "/${name}/public.json"));
          in {
            inherit name;
            value = {
              cacheUrl = reference.cache_url;
              cachePublicKeys = reference.cache_public_keys;
            };
          })
        deploymentNames);
      packagesFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in {
      lib = {
        deployments = deploymentReferences;
      };

      packages = forAllSystems (system:
        let
          pkgs = packagesFor system;
          nix-aws = pkgs.python3Packages.buildPythonApplication {
            pname = "nix-aws-build";
            version = "0.1.0";
            pyproject = true;
            src = self;
            build-system = [ pkgs.python3Packages.setuptools ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            nativeCheckInputs = [ pkgs.python3Packages.pytest ];
            pythonImportsCheck = [ "nix_aws" ];
            checkPhase = ''
              runHook preCheck
              pytest -q tests/unit
              runHook postCheck
            '';
            postFixup = ''
              wrapProgram $out/bin/nix-aws \
                --prefix PATH : ${nixpkgs.lib.makeBinPath [
                  pkgs.awscli2
                  pkgs.coreutils
                  pkgs.less
                  pkgs.nix
                  pkgs.nix-output-monitor
                  pkgs.openssh
                  pkgs.ssm-session-manager-plugin
                ]}
            '';
          };
        in {
          inherit nix-aws;
          default = nix-aws;
        });

      devShells = forAllSystems (system:
        let
          pkgs = packagesFor system;
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              actionlint
              awscli2
              gh
              jq
              opentofu
              packer
              python3Packages.pytest
              ripgrep
              ruff
              shellcheck
              shfmt
              ssm-session-manager-plugin
            ];
          };
        });

      checks = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          fixture = pkgs.callPackage ./tests/fixture/package.nix { };
          cli-unit = self.packages.${system}.nix-aws;
        });
    };
}
