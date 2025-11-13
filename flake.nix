{
  description = "headless browser designed for AI and automation";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.05";

    zigPkgs.url = "github:mitchellh/zig-overlay";
    zigPkgs.inputs.nixpkgs.follows = "nixpkgs";

    zlsPkg.url = "github:zigtools/zls/0.15.0";
    zlsPkg.inputs.zig-overlay.follows = "zigPkgs";
    zlsPkg.inputs.nixpkgs.follows = "nixpkgs";

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      zigPkgs,
      zlsPkg,
      fenix,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [
          (final: prev: {
            zigpkgs = zigPkgs.packages.${prev.system};
            zls = zlsPkg.packages.${prev.system}.default;
          })
        ];

        pkgs = import nixpkgs {
          inherit system overlays;
        };

        rustToolchain = fenix.packages.${system}.stable.toolchain;

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
              zigpkgs."0.15.2"
              zls
              rustToolchain
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
            ];
        };
      in
      {
        devShells.default = fhs.env;
      }
    );
}
