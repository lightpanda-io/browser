{
  description = "headless browser designed for AI and automation";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.05";
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

        # We need crtbeginS.o for building.
        crtFiles = pkgs.runCommand "crt-files" { } ''
          mkdir -p $out/lib
          cp -r ${pkgs.gcc.cc}/lib/gcc $out/lib/gcc
        '';

        # This build pipeline is very unhappy without an FHS-compliant env.
        fhs = pkgs.buildFHSEnv {
          name = "fhs-shell";
          multiArch = true;
          targetPkgs =
            pkgs: with pkgs; [
              # Build Tools
              zig
              zls
              python3
              pkg-config
              cmake
              gperf

              # GCC
              gcc
              gcc.cc.lib
              crtFiles

              # Libaries
              expat.dev
              glib.dev
              glibc.dev
              zlib
              zlib.dev
            ];
        };
      in
      {
        devShells.default = fhs.env;
      }
    );
}
