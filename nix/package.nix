{
  src,
  lib,
  pkgs,
  stdenv,
  fetchurl,
  zig,
  craneLib,
  version,
  buildInputs ? [ ],
}:
let
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

  zigV8Tag = "v0.5.7";
  v8Version = "14.9.207.35";

  v8 = fetchurl {
    url = "https://github.com/lightpanda-io/zig-v8-fork/releases/download/${zigV8Tag}/libc_v8_${v8Version}_${v8Archive.platform}.a";
    hash = v8Archive.hash;
  };

  zigDeps = zig.fetchDeps {
    inherit src version;
    name = "lightpanda";
    # Whenever build.zig.zon is updated, this must be updated too.
    hash = "sha256-VEb7BpVQ2CEj6KYQLidlWJYDqrwUDDJKXFtxZxBbuQs=";
  };

  rustFfiLib = "liblightpanda_ffi.a";
  rustLib = craneLib.buildPackage {
    pname = "lightpanda-ffi";
    inherit version;
    src = src + "/src/rust";
    cargoExtraArgs = "-p lightpanda-ffi";
    doCheck = false;
  };
in
zig.makePackage {
  inherit stdenv src zigDeps;
  pname = "lightpanda";
  version = "${version}-nix";

  nativeBuildInputs = buildInputs ++ [
    pkgs.autoPatchelfHook
  ];

  zigReleaseMode = "fast";
  zigFlagsArray = [
    "-Dtarget=${stdenv.hostPlatform.parsed.cpu.name}-${stdenv.hostPlatform.parsed.kernel.name}-${stdenv.hostPlatform.parsed.abi.name}"
    "-Dprebuilt_v8_path=${v8}"
    "-Dprebuilt_rust_path=${rustLib}/lib/${rustFfiLib}"
    "-Dversion=${version}"
  ];

  meta = {
    description = "Headless browser designed for AI and automation";
    homepage = "https://lightpanda.io";
    license = lib.licenses.agpl3Only;
    mainProgram = "lightpanda";
    platforms = builtins.attrNames v8Archives;
  };
}
