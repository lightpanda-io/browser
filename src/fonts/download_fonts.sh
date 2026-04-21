#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Downloading Liberation fonts..."
LIBERATION_VERSION="2.1.5"
LIBERATION_URL="https://github.com/liberationfonts/liberation-fonts/files/7261482/liberation-fonts-ttf-${LIBERATION_VERSION}.tar.gz"
curl -L -o liberation.tar.gz "$LIBERATION_URL"
tar xzf liberation.tar.gz --strip-components=1 "liberation-fonts-ttf-${LIBERATION_VERSION}/"*.ttf
rm liberation.tar.gz

echo "Downloading Ahem.ttf..."
AHEM_URL="https://web-platform-tests.org/writing-tests/ahem.ttf"
curl -L -o Ahem.ttf "$AHEM_URL"

echo "Done. Fonts downloaded to: $SCRIPT_DIR"
ls -la *.ttf *.TTF 2>/dev/null || true
