{
  description = "headless browser designed for AI and automation";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        # This build pipeline is very unhappy without an FHS-compliant env.
        fhs = pkgs.buildFHSEnv {
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
