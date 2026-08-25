#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../../lib/macos-defaults.sh"

macos_warn "Removing every pinned Dock application and showing only running applications."
macos_defaults com.apple.dock persistent-apps -array
macos_defaults com.apple.dock static-only -bool true
