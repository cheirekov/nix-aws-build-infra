{ runCommand }:
runCommand "nix-aws-build-fixture" { } ''
  mkdir -p $out
  printf 'cache-ok\n' > $out/result
''
