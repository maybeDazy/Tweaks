#!/usr/bin/env bash
set -euo pipefail

SCHEME="${1:-rootless}"
if [[ "$SCHEME" != "rootless" && "$SCHEME" != "roothide" ]]; then
  echo "Usage: ./scripts/build_deb_wsl.sh [rootless|roothide]"
  exit 1
fi

export THEOS="${THEOS:-$HOME/theos}"
export PATH="$THEOS/bin:$PATH"

make clean
make package THEOS_PACKAGE_SCHEME="$SCHEME"

echo "Built packages:"
ls -lah packages/*.deb
