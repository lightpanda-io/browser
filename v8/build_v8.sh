#!/usr/bin/env bash
set -o errexit #  exit on errors
set -o nounset # exit on use of uninitialized variable
set -o errtrace # inherits trap on ERR in function and subshell

source utils.sh

cp ../src/runtime/v8/binding.cpp src/
cp ../src/runtime/v8/inspector.h src/

ARCH=$(uname -m);
case "$OSTYPE" in
  darwin*)  OS="mac" ;;
  linux*)   OS="linux" ;;
  *)        fail "unsupported platform: ${OSTYPE}"
esac

MODE=${1:-"debug"}
OUT=out/${MODE}

if [[ ${OS} == "mac" && ${ARCH} == "arm64" ]] then
  # there's something wrong with the debug build of MacOS on ARM
  MODE=release
fi

if [[ ${MODE} == "release" ]] then
  IS_DEBUG="false"
  SYMBOL_LEVEL="0"
else
  IS_DEBUG="true"
  SYMBOL_LEVEL="1"
fi

mkdir -p src/zig
cp BUILD.gn src/zig/

tools/gn \
  --root=src \
  --root-target=//zig \
  --dotfile=.gn  \
  gen ${OUT} \
  --args="
    target_os=\"${OS}\"
    target_cpu=\"${ARCH}\"
    host_cpu=\"${ARCH}\"
    is_debug=${IS_DEBUG}
    symbol_level=${SYMBOL_LEVEL}
    is_official_build=false
  "

tools/ninja -C ${OUT} "c_v8"
