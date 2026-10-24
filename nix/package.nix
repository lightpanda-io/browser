{
  lib,
  stdenv,
  fetchurl,
  rustPlatform,
  autoPatchelfHook,
  patchelf,
  zig,
  rustToolchain,
  src,
  version,
}:

let
  # Keep in sync with the `zig-v8` and `v8` defaults in
  # .github/actions/install/action.yml (what `make download-v8` fetches).
  zigV8Tag = "v0.5.7";
  v8Version = "14.9.207.35";
  v8Archives = {
    aarch64-darwin = {
      platform = "macos_aarch64";
      hash = "sha256-AOXAPuMHof5uA+F3EdXyqzy3jTc1vJvFLJT4txzLBhg=";
    };
    x86_64-darwin = {
      platform = "macos_x86_64";
      hash = "sha256-q7y6djJ7ddXWWKNZId56cD2fSI+Ih7a+NI9ZhNQjOwQ=";
    };
    aarch64-linux = {
      platform = "linux_aarch64";
      hash = "sha256-Bk0Hna4tfLov6iKTYErpZLnqj3Q7eEeqfymPyvrUtjU=";
    };
    x86_64-linux = {
      platform = "linux_x86_64";
      hash = "sha256-qKymFSy10+obJhBH3104QTdq2Oo2DX6VqC9k3HhBdXQ=";
    };
  };
  v8Archive = v8Archives.${stdenv.hostPlatform.system};

  # Prebuilt V8, so the build doesn't compile V8 from source.
  v8 = fetchurl {
    url = "https://github.com/lightpanda-io/zig-v8-fork/releases/download/${zigV8Tag}/libc_v8_${v8Version}_${v8Archive.platform}.a";
    inherit (v8Archive) hash;
  };

  zigCacheSetup = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR/tmp"
  '';

  # build.zig.zon dependencies, fetched into zig-pkg/ as a fixed-output
  # derivation. Update the hash whenever build.zig.zon changes.
  zigDeps = stdenv.mkDerivation {
    # Fixed name: the store path then only depends on outputHash, so it is
    # reused across commits.
    name = "lightpanda-zig-deps";
    inherit src;

    nativeBuildInputs = [ zig ];

    dontConfigure = true;
    dontFixup = true;

    buildPhase = ''
      runHook preBuild
      ${zigCacheSetup}
      zig build --fetch=needed
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mv zig-pkg $out
      runHook postInstall
    '';

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-SkSujrlpxwSaa5myJ7cgjDAf4LzfPVWLIN6+8TtppU4=";
  };

  # Linux: zig can't detect the libc inside the sandbox (and falls back to
  # musl), so target glibc explicitly. An explicit version makes zig use its
  # bundled CRT; capped at the newest glibc zig 0.16 knows, like build.zig
  # does for -Ddev_fast. autoPatchelfHook then points at nixpkgs' glibc.
  glibcVersion =
    let
      v = lib.versions.majorMinor stdenv.cc.libc.version;
    in
    if lib.versionOlder "2.43" v then "2.43" else v;

  zigBuildFlags = lib.escapeShellArgs (
    [
      "-Doptimize=ReleaseFast"
      "-Dcpu=baseline"
      "-Dprebuilt_v8_path=${v8}"
      "-Dversion=${version}"
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      "-Dtarget=${stdenv.hostPlatform.parsed.cpu.name}-linux-gnu.${glibcVersion}"
    ]
  );

  cargoDeps = rustPlatform.importCargoLock {
    lockFile = src + "/src/rust/Cargo.lock";
  };
in
stdenv.mkDerivation {
  pname = "lightpanda";
  inherit version src;

  nativeBuildInputs = [
    zig
    rustToolchain
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    autoPatchelfHook
    patchelf
  ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    ${zigCacheSetup}

    cp -r ${zigDeps} zig-pkg
    chmod -R u+w zig-pkg

    # build.zig runs cargo; point it at the vendored crates.
    export CARGO_HOME="$TMPDIR/cargo-home"
    mkdir -p "$CARGO_HOME"
    cat > "$CARGO_HOME/config.toml" <<EOF
    [source.crates-io]
    replace-with = "vendored-sources"

    [source.vendored-sources]
    directory = "${cargoDeps}"

    [net]
    offline = true
    EOF

    # Same two steps as `make build`: create the V8 snapshot, then embed it.
    # The snapshot creator is installed and run by hand (not via the
    # `snapshot_creator` step) so that on Linux it can first be pointed at
    # nixpkgs' glibc: zig links it against the FHS /lib loader.
    zig build ${zigBuildFlags} extras --prefix "$TMPDIR/extras"
    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      patchelf \
        --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
        --set-rpath "${lib.getLib stdenv.cc.libc}/lib" \
        "$TMPDIR/extras/bin/lightpanda-snapshot-creator"
    ''}
    "$TMPDIR/extras/bin/lightpanda-snapshot-creator" src/snapshot.bin
    zig build ${zigBuildFlags} -Dsnapshot_path=../../snapshot.bin --prefix "$out"

    runHook postBuild
  '';

  dontInstall = true;

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/lightpanda version
    runHook postInstallCheck
  '';

  passthru = {
    inherit zigDeps cargoDeps v8;
  };

  meta = {
    description = "Headless browser designed for AI and automation";
    homepage = "https://lightpanda.io";
    license = lib.licenses.agpl3Only;
    mainProgram = "lightpanda";
    platforms = builtins.attrNames v8Archives;
  };
}
