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

    zon2nix.url = "github:nix-community/zon2nix";
  };

  outputs =
    {
      nixpkgs,
      zigPkgs,
      zlsPkg,
      fenix,
      flake-utils,
      zon2nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        zigVersion = "0.15.2";
        zigV8Version = "v0.3.4";
        v8Version = "14.0.365.4";
        cargoRoot = "src/html5ever";

        overlays = [
          (_final: prev: {
            zigpkgs = zigPkgs.packages.${prev.system};
            zls = zlsPkg.packages.${prev.system}.default;
          })
        ];

        pkgs = import nixpkgs {
          inherit system overlays;
        };

        rustToolchain = fenix.packages.${system}.stable.toolchain;

        zon2nixScript = pkgs.writeShellApplication {
          name = "zon2nix";
          runtimeInputs =
            with pkgs;
            [
              gawk
              ripgrep
            ]
            ++ [ zon2nix.packages.${system}.default ];
          text = # bash
            ''
              exec bash "$PWD/zon2nix.sh"
            '';
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
            pkgs:
            with pkgs;
            [
              # Build tools
              zigpkgs.${zigVersion}
              zls
              rustToolchain
              python3
              pkg-config
              cmake
              gperf

              # Toolchain/runtime pieces Zig expects during builds
              gcc
              gcc.cc.lib
              crtFiles

              # Libraries
              expat.dev
              glib.dev
              glibc.dev
              zlib
            ]
            ++ [ zon2nixScript ];
        };

        # regenerate with `nix run .#zon2nix`
        zigDeps = import ./build.zig.zon.nix { inherit (pkgs) linkFarm fetchgit fetchzip; };
        zigTarget = if pkgs.stdenv.hostPlatform.isAarch64 then "aarch64-linux-gnu" else "x86_64-linux-gnu";

        cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
          src = ./.;
          inherit cargoRoot;
          hash = "sha256-2eUx3gG6ufaEuHESGq33UGMNIN2W4LF96/QjyUFIops=";
        };

        prebuiltV8 =
          if pkgs.stdenv.hostPlatform.isLinux then
            let
              arch = if pkgs.stdenv.hostPlatform.isAarch64 then "aarch64" else "x86_64";
            in
            pkgs.fetchurl {
              url = "https://github.com/lightpanda-io/zig-v8-fork/releases/download/${zigV8Version}/libc_v8_${v8Version}_linux_${arch}.a";
              hash =
                if pkgs.stdenv.hostPlatform.isAarch64 then
                  "sha256-Zg5/e4c4r4zIQ7D7vCnnDPyxwU8H05HcIqfMSHFFE6k="
                else
                  "sha256-lu0iuSuV42vch+92sKlcw3NjC2ko4XljgyOMTCnQeKk=";
            }
          else
            null;

        prebuiltV8Arg = pkgs.lib.optionalString (prebuiltV8 != null) "-Dprebuilt_v8_path=${prebuiltV8}";
      in
      {
        packages = rec {
          default = lightpanda;
          lightpanda = pkgs.stdenv.mkDerivation {
            pname = "lightpanda";
            version = "unstable";
            src = ./.;

            nativeBuildInputs = [
              pkgs.rustPlatform.cargoSetupHook
              pkgs.zigpkgs.${zigVersion}
              rustToolchain
              pkgs.python3
              pkgs.pkg-config
              pkgs.cmake
              pkgs.gperf
              pkgs.gcc
              pkgs.patchelf
            ];

            buildInputs = [
              pkgs.expat
              pkgs.glib
              pkgs.glibc.dev
              pkgs.zlib
              pkgs.gcc.cc.lib
              crtFiles
            ];

            inherit cargoDeps cargoRoot;

            dontConfigure = true;

            buildPhase = ''
              runHook preBuild

              export HOME="$TMPDIR/home"
              export XDG_CACHE_HOME="$TMPDIR/.cache"
              export CARGO_HOME="$TMPDIR/cargo"
              export RUSTUP_HOME="$TMPDIR/rustup"
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
              export ZIG_LIBC="$TMPDIR/zig-libc.conf"
              export PATH=${pkgs.stdenv.cc}/bin:$PATH
              export CC=cc
              export CXX=c++

              mkdir -p "$HOME" "$XDG_CACHE_HOME" "$CARGO_HOME" "$RUSTUP_HOME" "$ZIG_GLOBAL_CACHE_DIR"
              zig libc > "$ZIG_LIBC"
              ln -s ${zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"

              cp -r "$src" source
              chmod -R u+w source
              cd source

              zig build install -Dtarget=${zigTarget} -Doptimize=ReleaseFast ${prebuiltV8Arg}
              patchelf --set-interpreter ${pkgs.stdenv.cc.bintools.dynamicLinker} zig-out/bin/lightpanda-snapshot-creator
              ./zig-out/bin/lightpanda-snapshot-creator src/snapshot.bin
              zig build install -Dtarget=${zigTarget} -Doptimize=ReleaseFast -Dgit_commit=dev -Dsnapshot_path=../../snapshot.bin ${prebuiltV8Arg}

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p "$out/bin"
              cp -v zig-out/bin/lightpanda "$out/bin/"
              patchelf --set-interpreter ${pkgs.stdenv.cc.bintools.dynamicLinker} "$out/bin/lightpanda"

              runHook postInstall
            '';

            meta.mainProgram = "lightpanda";
          };
        };

        apps = {
          zon2nix = {
            type = "app";
            program = pkgs.lib.getExe zon2nixScript;
          };
        };

        devShells.default = fhs.env;
      }
    );
}
