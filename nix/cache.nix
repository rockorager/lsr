{ pkgs, ... }:

pkgs.stdenv.mkDerivation {
  pname = "lsr-cache";
  version = "0.1.0";
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

  outputHash = "sha256-UeZOnpZ5iFF8f2WtO8qavzzau06/z/jPgYjcP9kHmWc=";
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
}
