{
  description = "headless browser designed for AI and automation";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    zig-flake = {
      url = "github:silversquirl/zig-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zls = {
      url = "github:zigtools/zls/eab2be0fd74443a27662da809b771c4ad0d2afcf";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.zig-flake.follows = "zig-flake";
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    crane = {
      url = "github:ipetkov/crane";
    };

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      zig-flake,
      zls,
      fenix,
      crane,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [
          (final: prev: {
            zig = zig-flake.packages.${prev.system}."zig_0_17_0";
            zls = zls.packages.${prev.system}.zls;
          })
        ];

        pkgs = import nixpkgs {
          inherit system overlays;
        };

        rustToolchain = fenix.packages.${system}.stable.toolchain;
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        # We need crtbeginS.o for building.
        crtFiles = pkgs.runCommand "crt-files" { } ''
          mkdir -p $out/lib
          cp -r ${pkgs.gcc.cc}/lib/gcc $out/lib/gcc
        '';

        buildDeps =
          pkgs: with pkgs; [
            gcc
            gcc.cc.lib
            crtFiles
            glibc.dev
          ];

        v8BuildDeps =
          pkgs: with pkgs; [
            python3
            pkg-config
            expat.dev
            glib.dev
            zlib
          ];

        # This build pipeline (V8 mainly) is very unhappy without an FHS-compliant env.
        fhs = pkgs.buildFHSEnv {
          name = "fhs-shell";
          multiArch = true;
          targetPkgs =
            pkgs:
            (buildDeps pkgs)
            ++ (v8BuildDeps pkgs)
            ++ (with pkgs; [
              zig
              zls
              rustToolchain
            ]);
        };

        lightpanda = pkgs.callPackage ./nix/package.nix {
          inherit craneLib;
          buildInputs = (buildDeps pkgs) ++ (with pkgs; [ zig ]);
          src = ./.;
          version = "1.0.0";
        };

      in
      {
        devShells.default = fhs.env;

        packages = {
          inherit lightpanda;
          default = lightpanda;
        };
      }
    );
}
