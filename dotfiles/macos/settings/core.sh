#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../../lib/macos-defaults.sh"

macos_log "Applying stable per-user macOS preferences"

# Keyboard and text entry
macos_defaults NSGlobalDomain KeyRepeat -int 1
macos_defaults NSGlobalDomain InitialKeyRepeat -int 15
macos_defaults NSGlobalDomain ApplePressAndHoldEnabled -bool false
macos_defaults NSGlobalDomain AppleKeyboardUIMode -int 2
macos_defaults NSGlobalDomain AppleShowScrollBars -string WhenScrolling
macos_defaults NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
macos_defaults NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
macos_defaults NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false
macos_defaults NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
macos_defaults NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false

# Finder
macos_defaults com.apple.finder AppleShowAllFiles -bool true
macos_defaults NSGlobalDomain AppleShowAllExtensions -bool true
macos_defaults com.apple.finder ShowPathbar -bool true
macos_defaults com.apple.finder ShowStatusBar -bool true
macos_defaults com.apple.finder ShowExternalHardDrivesOnDesktop -bool false
macos_defaults com.apple.finder ShowRemovableMediaOnDesktop -bool false
macos_defaults com.apple.desktopservices DSDontWriteNetworkStores -bool true
macos_run chflags nohidden "$HOME/Library"

# Dock and Mission Control settings exposed by System Settings
macos_defaults com.apple.dock autohide -bool true
macos_defaults com.apple.dock show-recents -bool false
macos_defaults com.apple.dock mineffect -string scale
macos_defaults com.apple.dock minimize-to-application -bool true
macos_defaults com.apple.dock show-process-indicators -bool true
macos_defaults com.apple.dock tilesize -int 48
macos_defaults com.apple.dock expose-group-apps -bool true
macos_defaults com.apple.dock enable-spring-load-actions-on-all-items -bool true

# Applications
macos_defaults com.apple.TextEdit RichText -bool false
