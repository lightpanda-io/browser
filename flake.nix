{
  description = "headless browser designed for AI and automation";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    zigPkgs = {
      url = "github:silversquirl/zig-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zlsPkg = {
      url = "github:zigtools/zls/0.16.0";
      inputs.zig-flake.follows = "zigPkgs";
      inputs.nixpkgs.follows = "nixpkgs";

    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
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
            zig = zigPkgs.packages.${prev.system}."zig_0_16_0";
            zls = zlsPkg.packages.${prev.system}.default;
          })
        ];

        pkgs = import nixpkgs {
          inherit system overlays;
        };

        rustToolchain = fenix.packages.${system}.stable.toolchain;

        buildTools =
          pkgs: with pkgs; [
            zig
            zls
            rustToolchain
            python3
            pkg-config
            cmake
            gperf
          ];

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
            pkgs:
            buildTools pkgs
            ++ (with pkgs; [
              # GCC
              gcc
              gcc.cc.lib
              crtFiles

              # Libraries
              expat.dev
              glib.dev
              glibc.dev
              zlib
            ]);
        };

        # macOS needs no FHS env. The stdenv shell pins DEVELOPER_DIR to a
        # nixpkgs Apple SDK, which zig picks up through xcrun, so builds don't
        # depend on the local Xcode (Zig 0.16's libc++ doesn't build against
        # the macOS 27 SDK).
        darwinShell = pkgs.mkShell {
          packages = buildTools pkgs;
        };

        # `-Dversion` with build metadata, as there is no .git in the Nix sandbox.
        zonVersion = builtins.head (
          builtins.match ".*\\.version = \"([^\"]+)\".*" (builtins.readFile ./build.zig.zon)
        );
        lightpanda = pkgs.callPackage ./nix/package.nix {
          inherit rustToolchain;
          src = self;
          version = "${zonVersion}+${self.shortRev or self.dirtyShortRev or "unknown"}";
        };

      in
      {
        packages.default = lightpanda;
        packages.lightpanda = lightpanda;

        devShells.default = if pkgs.stdenv.isDarwin then darwinShell else fhs.env;
      }
    );
}
