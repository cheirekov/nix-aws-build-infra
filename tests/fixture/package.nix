{ stdenv }:
stdenv.mkDerivation {
  pname = "nix-aws-build-fixture";
  version = "1";
  dontUnpack = true;

  buildPhase = ''
    cat > fixture.c <<'EOF'
    #include <stdio.h>
    int main(void) { return puts("cache-ok") < 0; }
    EOF
    $CC fixture.c -o nix-aws-fixture
  '';

  installPhase = ''
    install -Dm755 nix-aws-fixture $out/bin/nix-aws-fixture
  '';
}
