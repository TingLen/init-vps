#!/usr/bin/env sh
set -eu

if ! command -v fish >/dev/null 2>&1; then
  apt-get update
  apt-get install -y fish
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

exec fish "$SCRIPT_DIR/init-vps.fish" "$@"
