{
  description = "headless browser designed for AI and automation";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";

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

              # Libraries
              expat.dev
              glib.dev
              glibc.dev
              zlib
            ];
        };

        wptDocker =
          let
            demoRepo = pkgs.fetchFromGitHub {
              owner = "lightpanda-io";
              repo = "demo";
              rev = "6120b426dd3bb5d0b06512efe735f2e2778caa15";
              sha256 = "sha256-TaLi1uIpM+fUk8LFVnPOZM6rKbdHKmB2FcofvGHtcpM=";
            };

            wptRunner = pkgs.buildGoModule {
              name = "wptrunner";
              src = "${demoRepo}/wptrunner";
              vendorHash = "sha256-di6bylBVj5jDWCDNlZO0M4XFILHEdkGT6hP8ctxppgU=";
            };

            wptRepo = pkgs.fetchFromGitHub {
              owner = "lightpanda-io";
              repo = "wpt";
              rev = "8c4054c7d2662e5b695832c6a239a1e0ba2af86b";
              sha256 = "sha256-235E75oIQmYH4eyHRqCP3xXr2TRt1j2FRB6A2Iiy5Q8=";
            };

            entrypoint = pkgs.writeScript "entrypoint.sh" ''
              #!${pkgs.bash}/bin/bash
              set -e


              # setup hosts
              cd /wpt
              ./wpt make-hosts-file >> /etc/hosts
              ./wpt manifest
              ./wpt serve &
              WPT_PID=$!

              echo "Waiting for WPT server..."
              until curl -sf http://web-platform.test:8000/ > /dev/null 2>&1; do
                sleep 1
              done
              echo "WPT server ready"

              # start lightpanda
              /usr/local/bin/lightpanda serve --insecure-disable-tls-host-verification &
              LP_PID=$!

              # run the go runner
              ${wptRunner}/bin/wptrunner "$@" > /tmp/wptrunner.log 2>&1

              # cleanup
              kill $WPT_PID $LP_PID 2>/dev/null || true

              # now print the wptrunner results
              echo ""
              echo "=== WPT Results ==="
              cat /tmp/wptrunner.log
            '';
          in
          pkgs.dockerTools.buildImage {
            name = "wpt-server";
            tag = "latest";

            copyToRoot = pkgs.buildEnv {
              name = "image-root";
              paths = [
                pkgs.python3
                pkgs.bash
                pkgs.coreutils
                pkgs.git
                pkgs.curl
              ];
            };

            config = {
              Entrypoint = [ "${entrypoint}" ];
              WorkingDir = "/wpt";
            };

            extraCommands = ''
              mkdir -p usr/bin
              ln -s ${pkgs.coreutils}/bin/env usr/bin/env
              mkdir -p tmp
              mkdir -p wpt
              cp -r ${wptRepo}/. ./wpt
              chmod -R u+w ./wpt
            '';
          };
      in
      {
        devShells.default = fhs.env;

        apps.wpt = {
          type = "app";
          program = toString (
            pkgs.writeScript "run-wpt" ''
              #!${pkgs.bash}/bin/bash
              set -e

              BINARY=$(realpath "''${LIGHTPANDA_BIN:-./zig-out/bin/lightpanda}")
              CONTAINER_ID=$(podman run --rm -d \
                -v "$BINARY:/usr/local/bin/lightpanda" \
                docker-archive:${wptDocker} "$@")
              trap "podman kill $CONTAINER_ID 2>/dev/null || true" EXIT INT TERM
              podman logs -f "$CONTAINER_ID"
            ''
          );
        };
      }
    );
}
