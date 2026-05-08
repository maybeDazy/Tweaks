#!/usr/bin/env bash
set -euo pipefail
SCHEME="${1:-roothide}"
export THEOS="${THEOS:-$HOME/theos}"
make clean
make package THEOS_PACKAGE_SCHEME="$SCHEME" FINALPACKAGE=1
