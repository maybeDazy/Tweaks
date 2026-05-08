#!/usr/bin/env bash
set -euo pipefail

sudo apt update
sudo apt install -y bash curl git perl make clang ldid xz-utils unzip fakeroot dpkg-dev libplist-utils

if [ ! -d "$HOME/theos" ]; then
  git clone --recursive https://github.com/theos/theos.git "$HOME/theos"
else
  echo "Theos already exists at $HOME/theos"
fi

if ! grep -q 'export THEOS=' "$HOME/.bashrc"; then
  echo 'export THEOS=$HOME/theos' >> "$HOME/.bashrc"
  echo 'export PATH=$THEOS/bin:$PATH' >> "$HOME/.bashrc"
fi

export THEOS="$HOME/theos"
export PATH="$THEOS/bin:$PATH"

echo "Done. Run: source ~/.bashrc"
