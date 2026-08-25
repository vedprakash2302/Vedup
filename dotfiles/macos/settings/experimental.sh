#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../../lib/macos-defaults.sh"

require_supported_macos_internals
macos_warn "Applying undocumented, hardware-sensitive macOS preferences."

# Finder's opaque enum values and private underscore-prefixed keys
macos_defaults com.apple.finder FXPreferredViewStyle -string clmv
macos_defaults com.apple.finder NewWindowTarget -string PfHm
macos_defaults com.apple.finder _FXShowPosixPathInTitle -bool true
macos_defaults com.apple.finder _FXSortFoldersFirst -bool true
macos_defaults com.apple.finder _FXSortFoldersFirstOnDesktop -bool true
macos_defaults com.apple.finder FXDefaultSearchScope -string SCcf

# Function-key behavior and pointing devices
macos_defaults com.apple.HIToolbox AppleFnUsageType -int 1
macos_defaults com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
macos_defaults com.apple.AppleMultitouchTrackpad Clicking -bool true
macos_run defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
macos_defaults com.apple.driver.AppleBluetoothMultitouch.mouse MouseButtonMode -string TwoButton
macos_defaults com.apple.AppleMultitouchMouse MouseButtonMode -string TwoButton
macos_defaults com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag -bool true
macos_defaults com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerDrag -bool true
macos_defaults NSGlobalDomain com.apple.mouse.scaling -float 3
macos_defaults NSGlobalDomain com.apple.trackpad.scaling -float 3

# Hidden Dock animation controls and window dragging
macos_defaults com.apple.dock expose-animation-duration -float 0.1
macos_defaults com.apple.dock autohide-delay -float 0
macos_defaults com.apple.dock autohide-time-modifier -float 1
macos_defaults com.apple.dock showhidden -bool true
macos_defaults NSGlobalDomain NSWindowShouldDragOnGesture -bool true
