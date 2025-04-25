#!/usr/bin/env bash
set -o errexit #  exit on errors
set -o nounset # exit on use of uninitialized variable
set -o errtrace # inherits trap on ERR in function and subshell

source utils.sh

mkdir -p tools/

case "$OSTYPE" in
  darwin*)  OS="mac" ;;
  linux*)   OS="linux" ;;
  *)        fail "unsupported platform: ${OSTYPE}"
esac

if [ ! -f tools/gn ]; then
  download "https://chrome-infra-packages.appspot.com/dl/gn/gn/${OS}-amd64/+/latest" tools/gn.zip
  unzip -o tools/gn.zip -d tools
fi

if [ ! -f tools/ninja ]; then
  download "https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-${OS}.zip" tools/ninja.zip
  unzip -o tools/ninja.zip  -d tools
fi
