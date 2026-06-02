{ pkgs, zig, ... }:

pkgs.stdenv.mkDerivation {
  pname = "lsr-cache";
  version = "1.0.0";
  doCheck = false;
  src = ../.;

  nativeBuildInputs = [ zig ];

  buildPhase = ''
    export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
    zig build --fetch --summary none
  '';

  installPhase = ''
    mv $ZIG_GLOBAL_CACHE_DIR/p $out
  '';

  outputHash = "sha256-5+cBoNR6o4/0Tx8jJPwVFjofFU3PNSgHbQdxzt0jzZ8=";
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
}
