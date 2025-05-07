{
  description = "headless browser designed for AI and automation";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-24.11";

    iguana.url = "github:mookums/iguana";
    iguana.inputs.nixpkgs.follows = "nixpkgs";

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      iguana,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        zigVersion = "0_14_0";
        iguanaLib = iguana.lib.${system};

        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            (iguanaLib.mkZigOverlay zigVersion)
            (iguanaLib.mkZlsOverlay zigVersion)
          ];
        };

        # This build pipeline is very unhappy without an FHS-compliant env.
        fhs = pkgs.buildFHSUserEnv {
          name = "fhs-shell";
          targetPkgs =
            pkgs: with pkgs; [
              zig
              zls
              pkg-config
              cmake
              gperf
              expat.dev
              python3
              glib.dev
              glibc.dev
              zlib
              ninja
              gn
              gcc-unwrapped
              binutils
              clang
              clang-tools
            ];
        };
      in
      {
        devShells.default = fhs.env;
      }
    );
}
