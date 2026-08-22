{ ... }:
{
  nix.settings = {
    substituters = [
      "https://d387h9bqwrf18p.cloudfront.net"
      "https://cache.nixos.org"
    ];
    trusted-public-keys = [
      "nix-aws-build-infra-1:cU3u9sqlj9HCxWPQtV+jDuoFk7bPB5Ckru7DO4/ELvs="
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
  };
}
