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
    let
      zon = builtins.readFile ./build.zig.zon;
      version = builtins.elemAt (builtins.match ".*\\.version = \"([^\"]+)\".*" zon) 0;
    in
    flake-utils.lib.eachSystem
      [
        "x86_64-linux"
        "aarch64-linux"
      ]
      (
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

          minimalRustToolchain = fenix.packages.${system}.stable.minimalToolchain;
          rustToolchain = fenix.packages.${system}.stable.toolchain;
          craneLib = (crane.mkLib pkgs).overrideToolchain minimalRustToolchain;

          # We need crtbeginS.o for building on Linux.
          crtFiles = pkgs.runCommand "crt-files" { } ''
            mkdir -p $out/lib
            cp -r ${pkgs.gcc.cc}/lib/gcc $out/lib/gcc
          '';

          buildDeps =
            pkgs:
            with pkgs;
            [
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
            inherit version;
          };

        in
        {
          devShells.default = fhs.env;

          packages = {
            inherit lightpanda;
            default = lightpanda;
          };

          apps = {
            generate-v8-deps = {
              type = "app";
              program = "${pkgs.writeShellScript "generate-v8-deps" ''
                export PATH="${
                  pkgs.lib.makeBinPath [
                    pkgs.curl
                    pkgs.gnused
                    pkgs.coreutils
                    pkgs.gawk
                    pkgs.nix
                  ]
                }:$PATH"
                export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
                exec bash ${./nix/update-v8-deps.sh} "$PWD"
              ''}";
            };

            generate-zig-deps = {
              type = "app";
              program = "${pkgs.writeShellScript "generate-zig-deps" ''
                export PATH="${
                  pkgs.lib.makeBinPath [
                    pkgs.coreutils
                    pkgs.nix
                    pkgs.zig
                  ]
                }:$PATH"
                exec bash ${./nix/update-zig-deps-hash.sh} "$PWD"
              ''}";
            };
          };

        }
      );
}
