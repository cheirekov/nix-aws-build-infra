{
  outputs = { self }: {
    packages.x86_64-linux.default = derivation {
      name = "nix-aws-build-fixture";
      system = "x86_64-linux";
      builder = "/bin/sh";
      args = [ "-c" "mkdir -p $out; printf 'cache-ok\\n' > $out/result" ];
    };
  };
}
