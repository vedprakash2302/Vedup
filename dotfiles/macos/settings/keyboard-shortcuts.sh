#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../../lib/macos-defaults.sh"

require_supported_macos_internals
macos_warn "Replacing the complete macOS symbolic-hotkey domain with the tracked snapshot."
macos_run defaults import com.apple.symbolichotkeys "$SCRIPT_DIR/../keyboard-shortcuts.xml"
