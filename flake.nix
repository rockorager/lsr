{
  inputs = {
    utils.url = "github:numtide/flake-utils/main";
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem(system:
      let
        pkgs = import nixpkgs { inherit system; };
        cache = import ./nix/cache.nix { inherit pkgs; };
      in {
        devshells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [ zig zls ];
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "lsr";
          version = "0.2.0";
          doCheck = false;
          src = ./.;

          nativeBuildInputs = with pkgs; [ zig ];

          buildPhase = ''
            export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
            ln -sf ${cache} $ZIG_GLOBAL_CACHE_DIR/p
            zig build -Doptimize=ReleaseFast --summary all
          '';

          installPhase = ''
            install -Ds -m755 zig-out/bin/lsr $out/bin/lsr
          '';

          meta = with pkgs.lib; {
            description = "ls(1) but with io_uring";
            homepage = "https://tangled.sh/@rockorager.dev/lsr";
            maintainers = with maintainers; [ rockorager ];
            platforms = platforms.linux;
            license = licenses.mit;
          };
        };
      });
}
