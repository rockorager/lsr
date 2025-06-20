{ pkgs, ... }:

pkgs.stdenv.mkDerivation {
  pname = "lsr-cache";
  version = "0.2.0";
  doCheck = false;
  src = ../.;

  nativeBuildInputs = with pkgs; [ zig ];

  buildPhase = ''
    export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
    zig build --fetch --summary none
  '';

  installPhase = ''
    mv $ZIG_GLOBAL_CACHE_DIR/p $out
  '';

  outputHash = "sha256-lnOow40km0mcj21i2mTQiDGXLhcSxQ2kJoAgUhkQiEg=";
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
}
