#!/usr/bin/env bash
# Test helpers are passed by name to the parallel runner, so ShellCheck cannot
# see their indirect invocation.
# shellcheck disable=SC2317,SC2329

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
unset XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME
HOME="$TEST_ROOT/default-home"
export HOME
mkdir -p "$HOME"
VEDUP_TEST_INVENTORY_FILE="$TEST_ROOT/inventory-empty.tsv"
: > "$VEDUP_TEST_INVENTORY_FILE"
export VEDUP_TEST_INVENTORY_FILE

pass() { printf '[test] PASS: %s\n' "$*"; }
fail() { printf '[test] FAIL: %s\n' "$*" >&2; exit 1; }
CURRENT_TEST=initialization
unexpected_failure() {
  local exit_code="$1" line="$2"
  trap - ERR
  printf '[test] FAIL: unexpected exit %s in %s near line %s\n' "$exit_code" "$CURRENT_TEST" "$line" >&2
  exit "$exit_code"
}
trap 'unexpected_failure "$?" "$LINENO"' ERR
run_test() { CURRENT_TEST="$1"; "$2"; }
test_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

syntax_checks() {
  while IFS= read -r script; do bash -n "$script"; done < <(
    find "$REPO_ROOT" -path "$REPO_ROOT/.git" -prune -o -type f -print | while IFS= read -r file; do
      [ "$(head -n 1 "$file" 2>/dev/null || true)" = '#!/usr/bin/env bash' ] && printf '%s\n' "$file"
    done
  )
  pass "Bash syntax"

  if command -v shellcheck >/dev/null 2>&1; then
    while IFS= read -r script; do shellcheck -x "$script"; done < <(
      find "$REPO_ROOT" -path "$REPO_ROOT/.git" -prune -o -type f -print | while IFS= read -r file; do
        [ "$(head -n 1 "$file" 2>/dev/null || true)" = '#!/usr/bin/env bash' ] && printf '%s\n' "$file"
      done
    )
    pass "ShellCheck"
  fi

  python3 - <<'PY' "$REPO_ROOT"
import json
import pathlib
import plistlib
import sys
import tomllib

root = pathlib.Path(sys.argv[1])
json.loads((root / "dotfiles/nvim/.config/nvim/lazyvim.json").read_text())
json.loads((root / "dotfiles/cursor/Library/Application Support/Cursor/User/settings.json").read_text())
tomllib.loads((root / "mise.toml").read_text())
with (root / "dotfiles/macos/keyboard-shortcuts.xml").open("rb") as shortcuts:
    plistlib.load(shortcuts)
PY
  pass "JSON, TOML, and plist parsing"

  forbidden_fork_name="Mac""AutoSetup"
  forbidden_state_name="mac""autosetup"
  forbidden_parent="N""Laundry"
  if grep -R -I -E --exclude-dir=.git \
      "$forbidden_fork_name|$forbidden_state_name|$forbidden_parent" "$REPO_ROOT" >/dev/null; then
    fail "the independent source tree still contains a fork or pre-Vedup identity"
  fi
  grep -Fxq 'VEDUP_DEFAULT_REPOSITORY="vedprakash2302/Vedup"' "$REPO_ROOT/repository.env" || \
    fail "the canonical Vedup repository identity is missing"
  pass "independent repository identity"

  # shellcheck disable=SC1091
  . "$REPO_ROOT/versions.env"
  for pin in "$TPM_COMMIT" "$TMUX_NAVIGATOR_COMMIT" "$TMUX_RESURRECT_COMMIT" \
    "$TMUX_CONTINUUM_COMMIT" "$TMUX_SENSIBLE_COMMIT" "$TMUX_ONLINE_STATUS_COMMIT" \
    "$TMUX_BATTERY_COMMIT" "$TMUX_CATPPUCCIN_COMMIT"; do
    [[ "$pin" =~ ^[0-9a-f]{40}$ ]] || fail "invalid tmux plugin commit pin: $pin"
  done
  if grep -Eq '@plugin .*#[0-9a-f]{40}' "$REPO_ROOT/dotfiles/tmux/.tmux.conf"; then
    fail "TPM cannot install a commit hash via branch syntax"
  fi
  pass "tmux plugin pins"

  for pin in "$ZSH_AUTOSUGGESTIONS_COMMIT" "$ZSH_SYNTAX_HIGHLIGHTING_COMMIT" \
    "$ZSH_HISTORY_SUBSTRING_SEARCH_COMMIT" "$ZSH_COMPLETIONS_COMMIT" \
    "$ZSH_YOU_SHOULD_USE_COMMIT" "$ZSH_GIT_ALIAS_COMMIT"; do
    [[ "$pin" =~ ^[0-9a-f]{40}$ ]] || fail "invalid Zsh plugin commit pin: $pin"
  done
  pass "Zsh plugin pins"

  grep -Fq '/vedup/current' "$REPO_ROOT/dotfiles/zsh/.zsh.d/env.sh" || \
    fail "Zsh does not use the active Vedup release"

  for checksum in "$GUM_SHA_LINUX_X64" "$GUM_SHA_LINUX_ARM64" \
    "$GUM_SHA_MACOS_X64" "$GUM_SHA_MACOS_ARM64" \
    "$EZA_SHA_LINUX_X64" "$EZA_SHA_LINUX_ARM64"; do
    [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || fail "invalid Gum checksum: $checksum"
  done
  pass "interactive UI binary pins"

  REPO_ROOT="$REPO_ROOT" bash -c 'source "$REPO_ROOT/lib/apps.sh"; apps_manifest_validate' || \
    fail "the unified macOS application manifest is invalid"
  for required in $'workstation\tcask\tdocker-desktop' $'workstation\tcask\tfocus' \
    $'workstation\tcask\tlinear' $'workstation\tcask\tt3-code@nightly' \
    $'workstation\tcask\tzed' $'workstation\tmas\t6469021132'; do
    grep -Fq "$required" "$REPO_ROOT/profiles/macos/apps.tsv" || fail "required macOS app is absent: $required"
  done
  ! grep -Fq $'optional\tcask\tfocus' "$REPO_ROOT/profiles/macos/apps.tsv" || fail "Focus is duplicated in the optional bundle"
  grep -Fq 'brew trust --cask nikitabobko/tap/aerospace' "$REPO_ROOT/lib/platforms/macos.sh" || \
    fail "Aerospace cask trust is not scoped"
  grep -Fq 'brew trust --formula FelixKratz/formulae/borders' "$REPO_ROOT/lib/platforms/macos.sh" || \
    fail "Borders formula trust is not scoped"
  pass "unified macOS application manifest and scoped tap trust"
}

macos_settings_safety() {
  local core_output opt_in_output server_output
  core_output="$(HOME="$TEST_ROOT/macos-core" VEDUP_TEST_OS=macos \
    VEDUP_TEST_MACOS_MAJOR=26 "$REPO_ROOT/dotfiles/macos/setup-commands.sh" --dry-run 2>&1)"
  [[ "$core_output" == *"defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true"* ]] || \
    fail "stable settings do not use the expected desktopservices type"
  [[ "$core_output" != *"persistent-apps"* ]] || fail "default settings unexpectedly reset the Dock"
  [[ "$core_output" != *"symbolichotkeys"* ]] || fail "default settings unexpectedly replace shortcuts"
  [[ "$core_output" != *"AppleFnUsageType"* ]] || fail "default settings unexpectedly apply experimental keys"

  opt_in_output="$(HOME="$TEST_ROOT/macos-opt-ins" VEDUP_TEST_OS=macos \
    VEDUP_TEST_MACOS_MAJOR=26 "$REPO_ROOT/dotfiles/macos/setup-commands.sh" --dry-run \
      --minimal-dock --keyboard-shortcuts --experimental 2>&1)"
  [[ "$opt_in_output" == *"persistent-apps -array"* ]] || fail "minimal Dock option is not applied"
  [[ "$opt_in_output" == *"defaults import com.apple.symbolichotkeys"* ]] || fail "shortcut option is not applied"
  [[ "$opt_in_output" == *"com.apple.AppleMultitouchMouse MouseButtonMode -string TwoButton"* ]] || \
    fail "experimental mouse preference uses an invalid domain or type"
  [[ "$opt_in_output" != *"AppleMultitouchMouse.plist"* ]] || fail "mouse domain incorrectly includes .plist"

  server_output="$(HOME="$TEST_ROOT/macos-server-settings" VEDUP_TEST_OS=macos \
    VEDUP_TEST_ARCH=arm64 "$REPO_ROOT/bin/setup" --profile server --dry-run \
      --no-shell-change --no-verify --skip-plugins 2>&1)"
  [[ "$server_output" != *"Applying stable per-user macOS preferences"* ]] || \
    fail "server profile unexpectedly applies macOS preferences"

  if HOME="$TEST_ROOT/macos-conflict" VEDUP_TEST_OS=macos VEDUP_TEST_ARCH=arm64 \
    "$REPO_ROOT/bin/setup" --dry-run --no-macos-defaults --minimal-dock >/dev/null 2>&1; then
    fail "contradictory macOS preference flags were accepted"
  fi
  pass "macOS preference safety and opt-ins"
}

macos_preference_rollback() {
  local fake_bin="$TEST_ROOT/macos-rollback-bin" test_home="$TEST_ROOT/macos-rollback-home"
  local defaults_log="$TEST_ROOT/macos-defaults.log" write_count="$TEST_ROOT/macos-write-count"
  local rollback_file="$TEST_ROOT/macos-parent-rollback" backup_dir real_uname
  mkdir -p "$fake_bin" "$test_home"
  real_uname="$(command -v uname)"

  cat > "$fake_bin/uname" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = -s ]; then printf 'Darwin\n'; else exec "$real_uname" "\$@"; fi
EOF
  cat > "$fake_bin/defaults" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
scope=user
if [ "${1:-}" = -currentHost ]; then scope=host; shift; fi
command_name="${1:-}"; shift || true
printf '%s|%s|%s\n' "$scope" "$command_name" "$*" >> "$VEDUP_FAKE_DEFAULTS_LOG"
case "$command_name" in
  export)
    destination="${2:--}"
    plist='<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>'
    if [ "$destination" = - ]; then printf '%s\n' "$plist"; else printf '%s\n' "$plist" > "$destination"; fi
    ;;
  read) exit 1 ;;
  write)
    count="$(sed -n '1p' "$VEDUP_FAKE_WRITE_COUNT" 2>/dev/null || printf 0)"
    count=$((count + 1))
    printf '%s\n' "$count" > "$VEDUP_FAKE_WRITE_COUNT"
    if [ "$count" -eq "${VEDUP_FAKE_FAIL_WRITE:-0}" ]; then exit 73; fi
    ;;
  import|delete) : ;;
esac
EOF
  chmod +x "$fake_bin/uname" "$fake_bin/defaults"

  if PATH="$fake_bin:$PATH" HOME="$test_home" VEDUP_TEST_OS=macos \
    VEDUP_FAKE_DEFAULTS_LOG="$defaults_log" VEDUP_FAKE_WRITE_COUNT="$write_count" \
    VEDUP_FAKE_FAIL_WRITE=3 VEDUP_MACOS_ROLLBACK_FILE="$rollback_file" \
    "$REPO_ROOT/dotfiles/macos/setup-commands.sh" >/dev/null 2>&1; then
    fail "an injected macOS preference write failure unexpectedly succeeded"
  fi
  [ ! -e "$rollback_file" ] || fail "immediate preference rollback left its parent marker armed"
  grep -q '|import|' "$defaults_log" || fail "immediate preference failure did not restore exported domains"
  grep -q '|delete|' "$defaults_log" || fail "immediate preference failure did not remove newly introduced keys"
  backup_dir="$(tail -n 1 "$test_home/.local/state/vedup/macos-preferences.list")"
  [ -r "$backup_dir/keys.tsv" ] || fail "macOS preference backup omitted touched-key existence metadata"

  : > "$defaults_log"
  printf '%s\n' "$backup_dir" > "$rollback_file"
  if PATH="$fake_bin:$PATH" HOME="$test_home" VEDUP_STATE_DIR="$test_home/.local/state/vedup" \
    VEDUP_MACOS_ROLLBACK_FILE="$rollback_file" VEDUP_FAKE_DEFAULTS_LOG="$defaults_log" \
    VEDUP_FAKE_WRITE_COUNT="$write_count" REPO_ROOT="$REPO_ROOT" bash -c '
      source "$REPO_ROOT/lib/common.sh"
      false
      setup_cleanup
    ' >/dev/null 2>&1; then
    fail "the simulated post-preference health failure unexpectedly succeeded"
  fi
  grep -q '|import|' "$defaults_log" || fail "post-configuration failure did not restore macOS preferences"
  pass "macOS preference rollback before and after health verification"
}

dry_run_matrix() {
  local target os distro arch profile mac_intel_output mac_arm_output mac_optional_output linux_output progress_output no_color_output wsl_output
  for target in 'linux ubuntu x64 server' 'linux ubuntu arm64 server' 'linux amzn x64 server' 'linux amzn arm64 server' 'macos macos x64 workstation' 'macos macos arm64 workstation'; do
    read -r os distro arch profile <<< "$target"
    HOME="$TEST_ROOT/dry-$os-$distro-$arch" \
      VEDUP_TEST_OS="$os" VEDUP_TEST_DISTRO="$distro" VEDUP_TEST_ARCH="$arch" \
      "$REPO_ROOT/bin/setup" --profile "$profile" --dry-run --no-shell-change --no-verify --skip-plugins >/dev/null
  done

  mac_intel_output="$(HOME="$TEST_ROOT/mac-intel-routing" VEDUP_TEST_OS=macos \
    VEDUP_TEST_ARCH=x64 "$REPO_ROOT/bin/setup" --dry-run --no-shell-change --no-verify --skip-plugins 2>&1)"
  [[ "$mac_intel_output" == *"brew install fd git-delta"* ]] || fail "Intel macOS fallback tools are not routed through Homebrew"
  [[ "$mac_intel_output" == *"brew install stow tmux btop eza"* ]] || fail "macOS eza is not routed through Homebrew"
  [[ "$mac_intel_output" != *"brew install git"* ]] || fail "safe sync attempted to install Homebrew Git"
  mac_arm_output="$(HOME="$TEST_ROOT/mac-arm-apps" VEDUP_TEST_OS=macos \
    VEDUP_TEST_ARCH=arm64 "$REPO_ROOT/bin/setup" --profile workstation --dry-run \
      --no-shell-change --no-verify --skip-plugins 2>&1)"
  [[ "$mac_arm_output" == *"brew install --cask"* && "$mac_arm_output" == *" zed"* && \
    "$mac_arm_output" == *" focus"* && "$mac_arm_output" == *" linear"* && \
    "$mac_arm_output" == *" t3-code@nightly"* ]] || \
    fail "the compulsory macOS cask set is missing Zed, Focus, Linear, or T3 Code Nightly"
  [[ "$mac_arm_output" == *"[dry-run] mas install 6469021132"* ]] || \
    fail "the macOS dry-run did not schedule PDFgear after installing mas"
  mac_optional_output="$(HOME="$TEST_ROOT/mac-optional-apps" VEDUP_TEST_OS=macos \
    VEDUP_TEST_ARCH=arm64 "$REPO_ROOT/bin/setup" --profile server --with-personal-apps \
      --dry-run --no-shell-change --no-verify --skip-plugins 2>&1)"
  [[ "$mac_optional_output" == *"brew install"*" mas"* && \
    "$mac_optional_output" == *"[dry-run] mas install 1552826194"* ]] || \
    fail "optional App Store apps do not install mas first when selected from the server profile"
  linux_output="$(HOME="$TEST_ROOT/linux-routing" VEDUP_TEST_OS=linux VEDUP_TEST_DISTRO=ubuntu \
    VEDUP_TEST_ARCH=x64 "$REPO_ROOT/bin/setup" --dry-run --no-shell-change --no-verify --skip-plugins 2>&1)"
  [[ "$linux_output" == *" btop"* ]] || fail "Linux btop is not routed through Mise"
  [[ "$linux_output" == *" carapace"* && "$linux_output" == *"eza_x86_64-unknown-linux-musl.tar.gz"* ]] || \
    fail "eza and Carapace are not installed cross-platform"
  progress_output="$(HOME="$TEST_ROOT/progress" VEDUP_TEST_OS=linux VEDUP_TEST_DISTRO=ubuntu \
    VEDUP_TEST_ARCH=x64 "$REPO_ROOT/bin/setup" --profile server --with-docker --dry-run \
      --no-shell-change --no-verify --skip-plugins 2>&1)"
  [[ "$progress_output" == *"Installing missing foundations"* ]] || fail "adaptive progress omitted a planned foundation stage"
  [[ "$progress_output" == *"Synchronizing configuration"* ]] || fail "adaptive progress omitted a planned configuration stage"
  [[ "$progress_output" == *"Preview ready"* && "$progress_output" == *"No machine changes were made."* ]] || \
    fail "dry-run completion summary is missing"
  no_color_output="$(NO_COLOR=1 HOME="$TEST_ROOT/no-color" VEDUP_TEST_OS=linux \
    VEDUP_TEST_DISTRO=ubuntu VEDUP_TEST_ARCH=x64 "$REPO_ROOT/bin/setup" --profile server \
      --dry-run --no-shell-change --no-verify --skip-plugins 2>&1)"
  if printf '%s' "$no_color_output" | LC_ALL=C grep -q $'\033'; then fail "NO_COLOR output contains ANSI escapes"; fi
  wsl_output="$(HOME="$TEST_ROOT/wsl-routing" VEDUP_TEST_OS=linux VEDUP_TEST_DISTRO=ubuntu \
    VEDUP_TEST_DISTRO_VERSION=24.04 VEDUP_TEST_ARCH=x64 VEDUP_TEST_WSL=1 \
    VEDUP_TEST_CHOICES=Exit VEDUP_NO_GUM_DOWNLOAD=1 "$REPO_ROOT/bin/install" 2>&1)"
  [[ "$wsl_output" == *"Ubuntu 24.04 / x64 (WSL2)"* ]] || fail "WSL2 was not identified in the guided installer"
  pass "Ubuntu, Amazon Linux, and macOS dry-run matrix"
}

interactive_installer() {
  local mac_output linux_output custom_output review_output home_output
  if ! mac_output="$(HOME="$TEST_ROOT/friendly-mac" VEDUP_TEST_OS=macos VEDUP_TEST_ARCH=arm64 \
    VEDUP_TEST_CHOICES=unused VEDUP_NO_GUM_DOWNLOAD=1 \
    VEDUP_INSTALLER_PRINT_ARGS=1 "$REPO_ROOT/bin/install" 2>&1)"; then
    fail "Mac interactive installer exited unsuccessfully: $mac_output"
  fi
  [[ "$mac_output" == *"Detected: macOS "* && "$mac_output" == *" / arm64"* ]] || \
    fail "interactive installer did not describe the detected Mac"
  [[ "$mac_output" == *"SETUP_ARGS --profile workstation"* && "$mac_output" == *"--macos-defaults"* && \
    "$mac_output" == *"--without-aws"* && "$mac_output" == *"--shell-change"* ]] || \
    fail "recommended Mac defaults did not map to stable setup arguments"
  [[ "$mac_output" != *"Experimental macOS preferences"* ]] || \
    fail "normal setup still exposes advanced macOS controls"

  if ! linux_output="$(HOME="$TEST_ROOT/friendly-linux" VEDUP_TEST_OS=linux VEDUP_TEST_ARCH=x64 \
    VEDUP_TEST_DISTRO=ubuntu VEDUP_TEST_CHOICES='AWS command-line tools,Docker Engine' \
    VEDUP_NO_GUM_DOWNLOAD=1 VEDUP_INSTALLER_PRINT_ARGS=1 \
    "$REPO_ROOT/bin/install" --customize 2>&1)"; then
    fail "Linux interactive installer exited unsuccessfully: $linux_output"
  fi
  [[ "$linux_output" == *"SETUP_ARGS --profile server --with-aws --with-docker"* && \
    "$linux_output" == *"--without-personal-apps"* && "$linux_output" == *"--shell-change"* ]] || \
    fail "Linux customization did not map to setup arguments"
  [[ "$linux_output" == *"Vedup"* && "$linux_output" == *"Nice to meet you! Let's set your machine up!"* && \
    "$linux_output" == *"__     __"* ]] || fail "friendly installer welcome is incomplete"

  if ! custom_output="$(HOME="$TEST_ROOT/friendly-custom" VEDUP_TEST_OS=macos VEDUP_TEST_ARCH=x64 \
    VEDUP_TEST_CHOICES='Recommended Mac applications,Safe macOS preferences,Choose individual applications…|Zed [workstation] — Fast collaborative code editor.,PDFgear [workstation] — PDF reader; editor; converter; and signing utility.' \
    VEDUP_NO_GUM_DOWNLOAD=1 VEDUP_INSTALLER_PRINT_ARGS=1 "$REPO_ROOT/bin/install" --customize 2>&1)"; then
    fail "Custom Mac interactive installer exited unsuccessfully: $custom_output"
  fi
  [[ "$custom_output" == *"SETUP_ARGS --profile workstation"* && "$custom_output" == *"--macos-defaults"* ]] || \
    fail "custom Mac component choices were not preserved"
  [[ "$custom_output" == *$'cask:cursor\t0'* && "$custom_output" != *$'cask:zed\t0'* && \
    "$custom_output" != *$'mas:6469021132\t0'* ]] || fail "individual Mac application choices were not mapped"

  review_output="$(HOME="$TEST_ROOT/friendly-review" VEDUP_TEST_OS=linux VEDUP_TEST_ARCH=x64 \
    VEDUP_TEST_DISTRO=ubuntu VEDUP_TEST_CHOICES='Show details|Exit' \
    VEDUP_NO_GUM_DOWNLOAD=1 "$REPO_ROOT/bin/install" 2>&1)"
  [[ "$review_output" == *"Ready to set up"* && "$review_output" == *"Install"* && \
    "$review_output" == *"Individual changes"* ]] || fail "one-confirmation setup review is incomplete"

  home_output="$(HOME="$TEST_ROOT/friendly-home" VEDUP_TEST_OS=linux VEDUP_TEST_ARCH=x64 \
    VEDUP_TEST_DISTRO=ubuntu VEDUP_TEST_CHOICES=Exit VEDUP_NO_GUM_DOWNLOAD=1 \
    "$REPO_ROOT/bin/install" --home 2>&1)"
  [[ "$home_output" == *"Detected:"* ]] || fail "Vedup home menu did not open"
  pass "simplified installer, customization, and home-menu mapping"
}

saved_application_choices() {
  local choices_home="$TEST_ROOT/choices-home" choices_file="$TEST_ROOT/choices.tsv" persisted_home
  mkdir -p "$choices_home"
  HOME="$choices_home" REPO_ROOT="$REPO_ROOT" CHOICES_FILE="$choices_file" bash -c '
    set -Eeuo pipefail
    source "$REPO_ROOT/lib/apps.sh"
    source "$REPO_ROOT/lib/choices.sh"
    OS=macos PROFILE=workstation WITH_PERSONAL_APPS=0
    choices_defaults
    choices_set_override "cask:cursor" 0
    choices_set_override "formula:FelixKratz/formulae/borders" 0
    choices_write_file "$CHOICES_FILE"
    CHOICES_WORKSTATION_BUNDLE=0 CHOICES_OPTIONAL_BUNDLE=1 CHOICES_APP_OVERRIDES=""
    choices_load "$CHOICES_FILE"
    choices_match_file "$CHOICES_FILE"
    ! choices_app_selected workstation cask cursor
    ! choices_app_selected workstation formula FelixKratz/formulae/borders
    choices_app_selected workstation cask zed
    ! choices_app_selected optional cask warp
    CHOICES_OPTIONAL_BUNDLE=1
    ! choices_match_file "$CHOICES_FILE"
  ' || fail "bundle and per-application choices did not round-trip"
  grep -Fq $'app\tformula:FelixKratz/formulae/borders\t0' "$choices_file" || \
    fail "tapped formula choice lost its full identifier"
  printf 'schema\t1\nbundle\tworkstation\t2\nbundle\toptional\t0\n' > "$choices_file"
  if HOME="$choices_home" VEDUP_CHOICES_FILE="$choices_file" REPO_ROOT="$REPO_ROOT" bash -c \
      'source "$REPO_ROOT/lib/choices.sh"; choices_load_or_default' >/dev/null 2>&1; then
    fail "invalid saved choices were silently replaced with defaults"
  fi
  persisted_home="$TEST_ROOT/choices-persisted-home"
  HOME="$persisted_home" VEDUP_TEST_OS=macos VEDUP_TEST_ARCH=arm64 \
    VEDUP_APP_OVERRIDES=$'cask:cursor\t0\ncask:ghostty\t0\ncask:nikitabobko/tap/aerospace\t0' \
    "$REPO_ROOT/bin/setup" --dotfiles-only --profile workstation --skip-plugins --no-shell-change --no-verify >/dev/null
  grep -Fqx $'app\tcask:cursor\t0' "$persisted_home/.local/state/vedup/choices.tsv" || \
    fail "a component-only synchronization did not persist changed application choices"
  if grep -Eq '^stow_packages.*(cursor|ghostty|aerospace)' "$persisted_home/.local/state/vedup/state.tsv"; then
    fail "deselected macOS applications still linked their GUI configuration"
  fi
  pass "forward-compatible bundle and per-application choice persistence"
}

concise_progress() {
  local concise_home="$TEST_ROOT/concise-home" verbose_home="$TEST_ROOT/verbose-home"
  local concise_output verbose_output concise_log activity_output activity_home="$TEST_ROOT/activity-home"
  mkdir -p "$concise_home" "$verbose_home" "$activity_home"

  if ! concise_output="$(HOME="$concise_home" TERM=xterm-256color VEDUP_TEST_COMPACT=1 \
    "$REPO_ROOT/bin/setup" --dotfiles-only --skip-plugins --no-shell-change --no-verify 2>&1)"; then
    fail "concise dotfile sync exited unsuccessfully: $concise_output"
  fi
  [[ "$concise_output" == *"Concise view: full output is being saved"* ]] || \
    fail "concise installation does not identify its detailed log"
  [[ "$concise_output" == *"Your machine is ready"* ]] || fail "concise installation did not show its completion summary"
  concise_log="$(find "$concise_home/.local/state/vedup/logs" -type f -name '*.log' -print -quit)"
  grep -q '\[setup\] Linking zsh dotfiles' "$concise_log" || fail "concise installation did not retain command output"

  if ! activity_output="$(HOME="$activity_home" TERM=xterm-256color VEDUP_TEST_COMPACT=1 \
    VEDUP_ACTIVITY_INTERVAL=0.05 bash -c '
      set -Eeuo pipefail
      . "$1"
      DRY_RUN=0 VERBOSE=0 PROGRESS_TOTAL=1 PROFILE=test
      progress_init
      progress_header "test machine" "$PROFILE"
      progress_begin "Downloading a large package" "Show recent activity without scrolling."
      printf "large-download-marker\\n"
      sleep 0.2
      progress_done
      progress_finish
    ' _ "$REPO_ROOT/lib/common.sh" 2>&1)"; then
    fail "concise activity-feed simulation exited unsuccessfully: $activity_output"
  fi
  [[ "$activity_output" == *"Working ·"* && "$activity_output" == *"large-download-marker"* ]] || \
    fail "concise dashboard does not refresh recent command activity"

  if ! verbose_output="$(HOME="$verbose_home" TERM=xterm-256color VEDUP_TEST_COMPACT=1 \
    "$REPO_ROOT/bin/setup" --dotfiles-only --skip-plugins --no-shell-change --no-verify --verbose 2>&1)"; then
    fail "verbose dotfile sync exited unsuccessfully: $verbose_output"
  fi
  [[ "$verbose_output" == *"[setup] Linking zsh dotfiles"* ]] || fail "--verbose did not stream command output"
  pass "fixed concise dashboard and verbose output override"
}

administrator_approval() {
  local fake_bin="$TEST_ROOT/fake-sudo-bin" sudo_log="$TEST_ROOT/fake-sudo.log"
  local prompt_log="$TEST_ROOT/fake-sudo-prompt.log" auth_marker="$TEST_ROOT/fake-sudo.auth"
  mkdir -p "$fake_bin"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "$VEDUP_TEST_SUDO_LOG"' \
    'if [ "${VEDUP_TEST_SUDO_MODE:-}" = prompt ] && [ "$*" = "-n true" ] && [ ! -e "$VEDUP_TEST_SUDO_AUTH" ]; then exit 1; fi' \
    'if [ "$*" = "-v" ] && [ -n "${VEDUP_TEST_SUDO_AUTH:-}" ]; then : > "$VEDUP_TEST_SUDO_AUTH"; fi' \
    > "$fake_bin/sudo"
  chmod +x "$fake_bin/sudo"

  PATH="$fake_bin:$PATH" VEDUP_TEST_SUDO_LOG="$sudo_log" bash -c '
    set -Eeuo pipefail
    . "$1"
    DRY_RUN=0
    sudo_acquire
    sudo_run /usr/bin/true
    sudo_release
  ' _ "$REPO_ROOT/lib/common.sh" >/dev/null

  grep -Fxq -- '-n true' "$sudo_log" || fail "setup did not probe passwordless sudo with a real command"
  ! grep -Fxq -- '-v' "$sudo_log" || fail "passwordless sudo unnecessarily requested a password"
  grep -Fxq -- '-n /usr/bin/true' "$sudo_log" || fail "privileged commands can still open a hidden prompt"

  PATH="$fake_bin:$PATH" VEDUP_TEST_SUDO_LOG="$prompt_log" \
    VEDUP_TEST_SUDO_MODE=prompt VEDUP_TEST_SUDO_AUTH="$auth_marker" bash -c '
      set -Eeuo pipefail
      . "$1"
      DRY_RUN=0
      sudo_acquire
      sudo_release
    ' _ "$REPO_ROOT/lib/common.sh" >/dev/null
  grep -Fxq -- '-v' "$prompt_log" || fail "password-required sudo did not request visible approval"
  pass "single visible administrator approval and non-interactive sudo"
}

parallel_and_recovery() {
  local parallel_root="$TEST_ROOT/parallel" index holder_pid source_repo source_commit checkout bad_checkout
  mkdir -p "$parallel_root"
  # shellcheck disable=SC1091
  . "$REPO_ROOT/lib/common.sh"
  DRY_RUN=0

  parallel_task_a() {
    : > "$parallel_root/a"
    for index in {1..100}; do [ -e "$parallel_root/b" ] && return 0; sleep 0.01; done
    return 1
  }
  parallel_task_b() {
    : > "$parallel_root/b"
    for index in {1..100}; do [ -e "$parallel_root/a" ] && return 0; sleep 0.01; done
    return 1
  }
  parallel_task_fail() { return 7; }
  run_parallel_tasks 2 "barrier A|parallel_task_a" "barrier B|parallel_task_b" >/dev/null || \
    fail "independent setup tasks did not actually overlap"
  if run_parallel_tasks 2 "expected failure|parallel_task_fail" "successful peer|parallel_task_a" >/dev/null 2>&1; then
    fail "parallel task failure was not propagated"
  fi

  mkdir -p "$parallel_root/lock-home"
  HOME="$parallel_root/lock-home" bash -c '
    set -Eeuo pipefail
    source "$1"
    DRY_RUN=0
    setup_lock_acquire
    : > "$2"
    while [ ! -e "$3" ]; do sleep 0.02; done
  ' _ "$REPO_ROOT/lib/common.sh" "$parallel_root/lock-ready" "$parallel_root/lock-stop" &
  holder_pid=$!
  for index in {1..100}; do [ -e "$parallel_root/lock-ready" ] && break; sleep 0.01; done
  [ -e "$parallel_root/lock-ready" ] || fail "setup lock holder did not start"
  if HOME="$parallel_root/lock-home" bash -c '
    set -Eeuo pipefail; source "$1"; DRY_RUN=0; setup_lock_acquire
  ' _ "$REPO_ROOT/lib/common.sh" >/dev/null 2>&1; then
    fail "a concurrent Vedup run acquired the same setup lock"
  fi
  : > "$parallel_root/lock-stop"
  wait "$holder_pid"

  mkdir -p "$parallel_root/lock-home/.local/state/vedup/setup.lock"
  printf '99999999\n' > "$parallel_root/lock-home/.local/state/vedup/setup.lock/pid"
  HOME="$parallel_root/lock-home" bash -c '
    set -Eeuo pipefail; source "$1"; DRY_RUN=0; setup_lock_acquire; setup_lock_release
  ' _ "$REPO_ROOT/lib/common.sh" || fail "stale setup lock was not recovered"

  source_repo="$parallel_root/source.git"
  checkout="$parallel_root/checkout"
  bad_checkout="$parallel_root/bad-checkout"
  git init --quiet "$source_repo"
  git -C "$source_repo" config user.name Vedup-Test
  git -C "$source_repo" config user.email vedup-test@example.invalid
  printf 'pinned\n' > "$source_repo/plugin.zsh"
  git -C "$source_repo" add plugin.zsh
  git -C "$source_repo" commit --quiet -m pinned
  source_commit="$(git -C "$source_repo" rev-parse HEAD)"
  mkdir -p "$checkout.vedup-tmp-stale"
  VEDUP_BENCH_REPO="$REPO_ROOT" VEDUP_RETRY_DELAY=0 bash -c '
    set -Eeuo pipefail
    source_url="$1"; source_revision="$2"; destination="$3"
    setup_repo="$VEDUP_BENCH_REPO"; set --; source "$setup_repo/bin/setup"
    DRY_RUN=0
    sync_git_checkout "$source_url" "$source_revision" "$destination"
  ' _ "file://$source_repo" "$source_commit" "$checkout"
  [ "$(git -C "$checkout" rev-parse HEAD)" = "$source_commit" ] || fail "atomic plugin checkout used the wrong commit"
  [ ! -e "$checkout.vedup-tmp-stale" ] || fail "stale interrupted plugin checkout was not cleaned"
  mv "$source_repo" "$source_repo.offline"
  VEDUP_BENCH_REPO="$REPO_ROOT" VEDUP_RETRY_DELAY=0 bash -c '
    set -Eeuo pipefail
    source_url="$1"; source_revision="$2"; destination="$3"
    setup_repo="$VEDUP_BENCH_REPO"; set --; source "$setup_repo/bin/setup"
    DRY_RUN=0
    sync_git_checkout "$source_url" "$source_revision" "$destination"
  ' _ "file://$source_repo" "$source_commit" "$checkout" || fail "pinned rerun unnecessarily required the network"
  if VEDUP_BENCH_REPO="$REPO_ROOT" VEDUP_RETRY_DELAY=0 bash -c '
    set -Eeuo pipefail
    source_url="$1"; source_revision="$2"; destination="$3"
    setup_repo="$VEDUP_BENCH_REPO"; set --; source "$setup_repo/bin/setup"
    DRY_RUN=0
    sync_git_checkout "$source_url" "$source_revision" "$destination"
  ' _ "file://$source_repo" 0000000000000000000000000000000000000000 "$bad_checkout" >/dev/null 2>&1; then
    fail "invalid plugin revision unexpectedly installed"
  fi
  [ ! -e "$bad_checkout" ] || fail "failed plugin checkout left a partial destination"
  if compgen -G "$bad_checkout.vedup-tmp-*" >/dev/null; then fail "failed plugin checkout left temporary state"; fi
  pass "bounded parallelism, setup locking, retries, and atomic plugin recovery"
}

zsh_features() {
  local test_home="$TEST_ROOT/zsh-features" plugin_root fake_bin output second_output generator_log zsh_version
  plugin_root="$test_home/share/vedup/zsh/plugins"
  fake_bin="$test_home/bin"
  generator_log="$test_home/generators.log"
  zsh_version="$(zsh -fc 'print -r -- $ZSH_VERSION')"
  mkdir -p "$test_home/.zsh.d" "$fake_bin" \
    "$plugin_root/zsh-completions/src" "$plugin_root/git-alias" \
    "$plugin_root/zsh-you-should-use" "$plugin_root/zsh-autosuggestions" \
    "$plugin_root/zsh-history-substring-search" "$plugin_root/zsh-syntax-highlighting"
  for module in "$REPO_ROOT"/dotfiles/zsh/.zsh.d/*.sh; do
    ln -s "$module" "$test_home/.zsh.d/${module##*/}"
  done
  printf 'VEDUP_CUSTOM_MODULE=loaded\n' > "$test_home/.zsh.d/custom.sh"
  printf 'VEDUP_LOCAL_MODULE=loaded\n' > "$test_home/.zshrc.local"
  printf '#compdef vedup-test\n' > "$plugin_root/zsh-completions/src/_vedup-test"
  printf "alias ga='git add'\n" > "$plugin_root/git-alias/git-alias.plugin.zsh"
  printf 'check_alias_usage() { :; }\n' > "$plugin_root/zsh-you-should-use/you-should-use.plugin.zsh"
  printf '_zsh_autosuggest_start() { :; }\n' > "$plugin_root/zsh-autosuggestions/zsh-autosuggestions.zsh"
  printf '%s\n' 'history-substring-search-up() { :; }' 'history-substring-search-down() { :; }' \
    'zle -N history-substring-search-up' 'zle -N history-substring-search-down' \
    > "$plugin_root/zsh-history-substring-search/zsh-history-substring-search.zsh"
  printf '_zsh_highlight() { :; }\nVEDUP_SYNTAX_LOADED=last\n' \
    > "$plugin_root/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nprintf "fzf\\n" >> "$VEDUP_FAKE_GENERATOR_LOG"\nprintf "VEDUP_FZF_LOADED=1\\n"\n' \
    > "$fake_bin/fzf"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nprintf "carapace\\n" >> "$VEDUP_FAKE_GENERATOR_LOG"\nprintf "VEDUP_CARAPACE_LOADED=1\\n"\n' \
    > "$fake_bin/carapace"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nprintf "mise\\n" >> "$VEDUP_FAKE_GENERATOR_LOG"\nprintf "VEDUP_MISE_LOADED=1\\n"\n' \
    > "$fake_bin/mise"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nprintf "zoxide\\n" >> "$VEDUP_FAKE_GENERATOR_LOG"\nprintf "VEDUP_ZOXIDE_LOADED=1\\n"\n' \
    > "$fake_bin/zoxide"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nprintf "starship\\n" >> "$VEDUP_FAKE_GENERATOR_LOG"\nprintf "VEDUP_STARSHIP_LOADED=1\\n"\n' \
    > "$fake_bin/starship"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/eza"
  chmod +x "$fake_bin/fzf" "$fake_bin/carapace" "$fake_bin/mise" "$fake_bin/zoxide" \
    "$fake_bin/starship" "$fake_bin/eza"

  # shellcheck disable=SC2016
  output="$(HOME="$test_home" XDG_DATA_HOME="$test_home/share" VEDUP_FAKE_GENERATOR_LOG="$generator_log" \
    PATH="$fake_bin:/usr/bin:/bin" \
    TERM=xterm-256color zsh -fic '
      source "$1"
      [[ "$VEDUP_CUSTOM_MODULE" = loaded && "$VEDUP_LOCAL_MODULE" = loaded ]]
      [[ "$VEDUP_MISE_LOADED" = 1 && "$VEDUP_ZOXIDE_LOADED" = 1 && "$VEDUP_FZF_LOADED" = 1 ]]
      [[ "$VEDUP_CARAPACE_LOADED" = 1 && "$VEDUP_STARSHIP_LOADED" = 1 && "$VEDUP_SYNTAX_LOADED" = last ]]
      (( $+functions[_zsh_autosuggest_start] && $+functions[_zsh_highlight] ))
      (( $+widgets[history-substring-search-up] && $+aliases[ga] && $+functions[check_alias_usage] ))
      [[ "$fpath[1]" = */zsh-completions/src ]]
      [[ "$aliases[ls]" = "eza --group-directories-first --icons=auto" ]]
      print zsh-features-ok
    ' _ "$REPO_ROOT/dotfiles/zsh/.zshrc" 2>&1)"
  [[ "$output" == *"zsh-features-ok"* ]] || fail "modular Zsh feature stack did not load: $output"
  second_output="$(HOME="$test_home" XDG_DATA_HOME="$test_home/share" VEDUP_FAKE_GENERATOR_LOG="$generator_log" \
    PATH="$fake_bin:/usr/bin:/bin" TERM=xterm-256color zsh -fic '
      source "$1"
      [[ "$VEDUP_MISE_LOADED" = 1 && "$VEDUP_ZOXIDE_LOADED" = 1 && "$VEDUP_FZF_LOADED" = 1 ]]
      [[ "$VEDUP_CARAPACE_LOADED" = 1 && "$VEDUP_STARSHIP_LOADED" = 1 ]]
      print zsh-cache-ok
    ' _ "$REPO_ROOT/dotfiles/zsh/.zshrc" 2>&1)"
  [[ "$second_output" == *"zsh-cache-ok"* ]] || fail "cached Zsh integrations did not load: $second_output"
  for generator in mise zoxide fzf carapace starship; do
    [ "$(grep -c "^${generator}$" "$generator_log")" -eq 1 ] || \
      fail "$generator initialization was regenerated during a warm shell"
    zsh -n "$test_home/.cache/vedup/zsh/init/$generator.zsh" || fail "$generator cache is invalid"
  done
  [ -s "$test_home/.cache/vedup/zsh/zcompdump-${zsh_version}" ] || fail "completion cache was not created"
  pass "modular Zsh features and atomic warm-start caches"
}

release_asset() {
  local asset="$TEST_ROOT/bootstrap"
  sed -e 's/__VEDUP_RELEASE_REF__/v0.0.0/g' \
    -e 's/__VEDUP_RELEASE_COMMIT__/0000000000000000000000000000000000000000/g' \
    -e 's/__VEDUP_ARCHIVE_SHA256__/0000000000000000000000000000000000000000000000000000000000000000/g' \
    -e 's|__VEDUP_RELEASE_REPOSITORY__|vedprakash2302/Vedup|g' \
    "$REPO_ROOT/bootstrap" > "$asset"
  bash -n "$asset"
  ! grep -q '__VEDUP_' "$asset" || fail "release bootstrap still contains placeholders"
  grep -q 'bin/install' "$asset" || fail "release bootstrap does not route terminal users to the guided installer"
  ! grep -Eq 'git (clone|fetch|checkout)' "$asset" || fail "release bootstrap still depends on Git"
  pass "release bootstrap rendering"
}

vedup_self_update() {
  local update_root="$TEST_ROOT/self-update" fake_bin="$TEST_ROOT/self-update/bin" update_home="$TEST_ROOT/self-update/home"
  local bootstrap_fixture="$TEST_ROOT/self-update/bootstrap" invalid_fixture="$TEST_ROOT/self-update/invalid"
  local archive="$TEST_ROOT/self-update/vedup-v9.9.9.tar.gz" archive_sha output tool
  local symlink_launcher_home="$TEST_ROOT/self-update/symlink-launcher-home" preserved_before preserved_after
  mkdir -p "$fake_bin" "$update_home" "$update_root/payload/vedup-v9.9.9/bin"
  cp "$REPO_ROOT/repository.env" "$update_root/payload/vedup-v9.9.9/repository.env"
  for tool in install setup update doctor; do
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\nprintf "unexpected setup execution\\n" > "$HOME/setup-ran"\n' > "$update_root/payload/vedup-v9.9.9/bin/$tool"
    chmod +x "$update_root/payload/vedup-v9.9.9/bin/$tool"
  done
  printf '#!/usr/bin/env bash\nexit 0\n' > "$update_root/payload/vedup-v9.9.9/bin/vedup"
  chmod +x "$update_root/payload/vedup-v9.9.9/bin/vedup"
  (
    cd "$update_root/payload/vedup-v9.9.9"
    manifest="$TEST_ROOT/self-update-manifest"
    find . -type f ! -name .vedup-manifest.sha256 -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > "$manifest"
    mv "$manifest" .vedup-manifest.sha256
  )
  tar -czf "$archive" -C "$update_root/payload" vedup-v9.9.9
  archive_sha="$(test_sha256 "$archive")"
  cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then output="$2"; shift 2; else shift; fi
done
case "$output" in
  */bootstrap) cp "$VEDUP_TEST_BOOTSTRAP" "$output" ;;
  *) cp "$VEDUP_TEST_ARCHIVE" "$output" ;;
esac
EOF
  chmod +x "$fake_bin/curl"
  {
    cat <<'EOF'
#!/usr/bin/env bash
VEDUP_RELEASE_REF="v9.9.9"
VEDUP_RELEASE_COMMIT="0000000000000000000000000000000000000000"
EOF
    printf 'VEDUP_ARCHIVE_SHA256="%s"\n' "$archive_sha"
  } > "$bootstrap_fixture"
  printf '#!/usr/bin/env bash\nprintf unsafe\n' > "$invalid_fixture"
  mkdir -p "$update_home/.local/share/vedup/old-release/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$update_home/.local/share/vedup/old-release/bin/vedup"
  chmod +x "$update_home/.local/share/vedup/old-release/bin/vedup"
  ln -s "$update_home/.local/share/vedup/old-release" "$update_home/.local/share/vedup/current"
  ln -s "$update_home/.local/share/vedup/old-release" "$update_home/.local/share/vedup/applied"
  mkdir -p "$update_home/.local/state/vedup/transactions/interrupted" \
    "$update_home/.local/share/vedup/config/base" "$update_home/.local/share/vedup/config/worktree"
  printf 'schema\t1\nstatus\tcomplete\n' > "$update_home/.local/state/vedup/state.tsv"
  printf 'workstation_bundle\t1\n' > "$update_home/.local/state/vedup/choices.tsv"
  printf 'keep\tgit\tsystem\texternal\tinstalled\tcompatible\tRetain Git\n' > \
    "$update_home/.local/state/vedup/resources.tsv"
  printf 'pending\n' > "$update_home/.local/state/vedup/transactions/interrupted/journal.tsv"
  printf 'base\n' > "$update_home/.local/share/vedup/config/base/sentinel"
  printf 'local edit\n' > "$update_home/.local/share/vedup/config/worktree/sentinel"
  preserved_before="$(
    cd "$update_home"
    find .local/state/vedup .local/share/vedup/config -type f -print | LC_ALL=C sort |
      while IFS= read -r filepath; do printf '%s\t%s\n' "$filepath" "$(test_sha256 "$filepath")"; done
  )"
  output="$(HOME="$update_home" PATH="$fake_bin:/usr/bin:/bin" VEDUP_TEST_BOOTSTRAP="$bootstrap_fixture" \
    VEDUP_TEST_ARCHIVE="$archive" "$REPO_ROOT/bin/update" 2>&1)"
  [[ "$output" == *"Vedup updated to v9.9.9"* ]] || fail "vedup update did not activate the verified release"
  [ ! -e "$update_home/setup-ran" ] || fail "vedup update unexpectedly ran the machine setup"
  [ "$(readlink "$update_home/.local/share/vedup/current")" = \
    "$update_home/.local/share/vedup/releases/v9.9.9-000000000000" ] || fail "vedup update did not switch current atomically"
  [ "$(readlink "$update_home/.local/share/vedup/applied")" = "$update_home/.local/share/vedup/old-release" ] || \
    fail "vedup update changed the applied machine policy before synchronization"
  preserved_after="$(
    cd "$update_home"
    find .local/state/vedup .local/share/vedup/config -type f -print | LC_ALL=C sort |
      while IFS= read -r filepath; do printf '%s\t%s\n' "$filepath" "$(test_sha256 "$filepath")"; done
  )"
  [ "$preserved_before" = "$preserved_after" ] || \
    fail "vedup update changed current state, configuration, choices, resources, or an interrupted transaction"
  [[ "$output" == *"https://github.com/vedprakash2302/Vedup"* ]] || \
    fail "vedup update did not report the independent update repository"
  if [ ! -x "$update_home/.local/bin/vedup" ] || \
    ! grep -Fqx '# vedup-managed-launcher-v2' "$update_home/.local/bin/vedup"; then
    fail "vedup update did not install the stable command launcher"
  fi
  if output="$(HOME="$TEST_ROOT/self-update/invalid-home" PATH="$fake_bin:/usr/bin:/bin" \
      VEDUP_TEST_BOOTSTRAP="$invalid_fixture" VEDUP_TEST_ARCHIVE="$archive" \
      "$REPO_ROOT/bin/update" 2>&1)"; then
    fail "vedup update accepted invalid release metadata"
  fi
  [[ "$output" == *"invalid release tag"* ]] || fail "vedup update rejection was not actionable"
  output="$("$REPO_ROOT/bin/vedup" help)"
  [[ "$output" == *'update       Download, verify'* ]] || fail "vedup update is absent from command help"
  mkdir -p "$symlink_launcher_home/.local/bin"
  ln -s "$REPO_ROOT/bin/vedup" "$symlink_launcher_home/.local/bin/vedup"
  output="$(HOME="$symlink_launcher_home" "$symlink_launcher_home/.local/bin/vedup" help)"
  [[ "$output" == *'Usage: vedup'* ]] || fail "older symlink launcher derived the wrong repository root"
  pass "self-update-only verification and atomic activation"
}

safe_sync_invariants() {
  local mac_home="$TEST_ROOT/policy-mac" linux_home="$TEST_ROOT/policy-linux" mac_output linux_output
  local upgrade_home="$TEST_ROOT/policy-upgrade" upgrade_bin="$TEST_ROOT/policy-upgrade-bin" upgrade_inventory upgrade_output
  mkdir -p "$mac_home" "$linux_home" "$upgrade_home" "$upgrade_bin"
  mac_output="$(HOME="$mac_home" VEDUP_TEST_OS=macos VEDUP_TEST_ARCH=arm64 \
    "$REPO_ROOT/bin/setup" --profile workstation --dry-run --no-shell-change --no-macos-defaults --skip-plugins 2>&1)"
  [[ "$mac_output" == *"HOMEBREW_NO_INSTALL_UPGRADE=1 brew install --cask"* ]] || \
    fail "macOS applications are not installed in missing-only mode"
  [[ "$mac_output" != *"brew install git"* ]] || fail "safe sync planned Homebrew Git"
  [[ "$mac_output" != *"brew update"* && "$mac_output" != *"brew upgrade"* ]] || \
    fail "safe sync planned an implicit Homebrew update or upgrade"

  linux_output="$(HOME="$linux_home" VEDUP_TEST_OS=linux VEDUP_TEST_DISTRO=ubuntu \
    VEDUP_TEST_ARCH=x64 "$REPO_ROOT/bin/setup" --profile server --dry-run --no-shell-change --skip-plugins 2>&1)"
  [[ "$linux_output" == *"apt-get install -y --no-upgrade"* ]] || fail "Ubuntu packages are not installed in missing-only mode"
  [[ "$linux_output" != *"apt-get upgrade"* && "$linux_output" != *"apt upgrade"* ]] || fail "safe sync planned a general APT upgrade"

  if grep -R -E -n 'git config (--global )?.*(credential|helper)|(^|[[:space:]])(>|>>).*\.gitconfig|sed -i.*\.gitconfig' \
      "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/dotfiles" >/dev/null; then
    fail "Vedup contains a Git credential-helper or .gitconfig mutation"
  fi
  grep -Fq 'git|stow|tmux|btop|eza|fd|git-delta' "$REPO_ROOT/bin/capture" || \
    fail "capture can adopt Homebrew Git and violate the system-Git invariant"

  upgrade_inventory="$TEST_ROOT/policy-upgrade.tsv"
  printf 'command\tbrew\ncommand\tgit\npackage:cask\tcursor\noutdated-cask\tcursor\n' > "$upgrade_inventory"
  cat > "$upgrade_bin/brew" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  shellenv) exit 0 ;;
  list) exit 0 ;;
  outdated) [ "${*: -1}" = cursor ] && printf 'cursor\n'; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$upgrade_bin/brew"
  upgrade_output="$(HOME="$upgrade_home" PATH="$upgrade_bin:$PATH" VEDUP_TEST_INVENTORY_FILE="$upgrade_inventory" \
    VEDUP_TEST_OS=macos VEDUP_TEST_ARCH=arm64 "$REPO_ROOT/bin/setup" --profile workstation \
      --upgrade-apps --dry-run --no-shell-change --no-macos-defaults --skip-plugins 2>&1)"
  [[ "$upgrade_output" == *"brew upgrade --cask cursor"* ]] || fail "explicit --upgrade-apps did not plan an outdated GUI update"
  upgrade_output="$(HOME="$upgrade_home" PATH="$upgrade_bin:$PATH" VEDUP_TEST_INVENTORY_FILE="$upgrade_inventory" \
    VEDUP_SELECTED_APP_UPGRADES=cursor VEDUP_TEST_OS=macos VEDUP_TEST_ARCH=arm64 \
    "$REPO_ROOT/bin/setup" --profile workstation --scope apps --dry-run --no-shell-change \
      --no-macos-defaults --skip-plugins 2>&1)"
  [[ "$upgrade_output" == *"brew upgrade --cask cursor"* && \
    "$upgrade_output" != *"Installing missing foundations"* && "$upgrade_output" != *"Synchronizing configuration"* ]] || \
    fail "scoped application maintenance invoked unrelated setup stages"
  pass "missing-only provider policy and Git credential invariants"
}

mise_execution_boundary() {
  local boundary_root="$TEST_ROOT/mise-boundary" boundary_home="$TEST_ROOT/mise-boundary/home"
  local fake_bin="$TEST_ROOT/mise-boundary/bin" exec_log="$TEST_ROOT/mise-boundary/exec.log"
  local external_marker="$TEST_ROOT/mise-boundary/external-nvim" headless_log="$TEST_ROOT/mise-boundary/headless.log"
  mkdir -p "$boundary_home/.local/bin" "$fake_bin"
  cat > "$fake_bin/nvim" <<'EOF'
#!/usr/bin/env bash
: > "$VEDUP_EXTERNAL_NVIM_MARKER"
printf 'NVIM v0.9.0\n'
EOF
  chmod +x "$fake_bin/nvim"
  cat > "$boundary_home/.local/bin/mise" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s|%s\n' "${MISE_CONFIG_FILE:-}" "$*" >> "$VEDUP_MISE_EXEC_LOG"
case "${1:-}" in
  trust) exit 0 ;;
  exec)
    [ "${MISE_EXEC_AUTO_INSTALL:-}" = false ] || exit 84
    [ "${MISE_NOT_FOUND_AUTO_INSTALL:-}" = false ] || exit 85
    [ "${MISE_NOT_FOUND_SYSTEM_FALLBACK:-}" = false ] || exit 86
    shift
    [ "${1:-}" = -- ] && shift
    [ "${1:-}" = nvim ] || exit 81
    shift
    if [ "${1:-}" = --version ]; then
      printf 'NVIM v%s\n' "$VEDUP_FAKE_NVIM_VERSION"
      exit 0
    fi
    if IFS= read -r unexpected; then
      printf 'unexpected stdin: %s\n' "$unexpected" >&2
      exit 82
    fi
    printf '%s\n' "$*" > "$VEDUP_NVIM_HEADLESS_LOG"
    ;;
  *) exit 83 ;;
esac
EOF
  chmod +x "$boundary_home/.local/bin/mise"

  # A development stage can legitimately contain plugin or platform work but
  # no missing Mise tools. Empty subtasks must be no-ops under `set -u` so an
  # interrupted or partially configured machine can safely resume.
  mkdir -p \
    "$boundary_home/.local/share/vedup/zsh/plugins/zsh-autosuggestions" \
    "$boundary_home/.local/share/vedup/zsh/plugins/zsh-syntax-highlighting" \
    "$boundary_home/.local/share/vedup/zsh/plugins/zsh-history-substring-search" \
    "$boundary_home/.local/share/vedup/zsh/plugins/zsh-completions" \
    "$boundary_home/.local/share/vedup/zsh/plugins/zsh-you-should-use" \
    "$boundary_home/.local/share/vedup/zsh/plugins/git-alias" \
    "$boundary_home/.tmux/plugins/tpm" \
    "$boundary_home/.tmux/plugins/vim-tmux-navigator" \
    "$boundary_home/.tmux/plugins/tmux-resurrect" \
    "$boundary_home/.tmux/plugins/tmux-continuum" \
    "$boundary_home/.tmux/plugins/tmux-sensible" \
    "$boundary_home/.tmux/plugins/tmux-online-status" \
    "$boundary_home/.tmux/plugins/tmux-battery" \
    "$boundary_home/.tmux/plugins/tmux"
  HOME="$boundary_home" PATH="$fake_bin:/usr/bin:/bin" \
    bash -c 'root="$1"; set --; source "$root/bin/setup"; OS=linux; ARCH=x64; WITH_AWS=0; WITH_DOCKER=0; DRY_RUN=0; plan_reset; install_mise_tools; install_terminal_plugins' \
      _ "$REPO_ROOT" || fail "empty development subtasks were not safe no-ops"

  boundary_root="$REPO_ROOT"
  printf 'interactive input must not reach Neovim\n' | \
    HOME="$boundary_home" PATH="$fake_bin:/usr/bin:/bin" \
    VEDUP_MISE_EXEC_LOG="$exec_log" VEDUP_EXTERNAL_NVIM_MARKER="$external_marker" \
    VEDUP_NVIM_HEADLESS_LOG="$headless_log" VEDUP_FAKE_NVIM_VERSION=0.12.2 \
    bash -c 'root="$1"; set --; source "$root/bin/setup"; DRY_RUN=0; install_neovim_plugins' \
      _ "$boundary_root" || fail "pinned Neovim integration did not complete"
  [ ! -e "$external_marker" ] || fail "an older external Neovim shadowed the pinned Mise tool"
  grep -Fq "$REPO_ROOT/mise.toml|exec -- nvim --version" "$exec_log" || \
    fail "Neovim version verification did not use the release Mise configuration"
  grep -Fq -- '--headless +Lazy! restore +qa' "$headless_log" || \
    fail "LazyVim synchronization did not use pinned headless Neovim"

  : > "$exec_log"
  if HOME="$boundary_home" PATH="$fake_bin:/usr/bin:/bin" \
      VEDUP_MISE_EXEC_LOG="$exec_log" VEDUP_EXTERNAL_NVIM_MARKER="$external_marker" \
      VEDUP_NVIM_HEADLESS_LOG="$headless_log" VEDUP_FAKE_NVIM_VERSION=0.10.0 \
      bash -c 'root="$1"; set --; source "$root/bin/setup"; DRY_RUN=0; install_neovim_plugins' \
        _ "$boundary_root" >/dev/null 2>&1; then
    fail "Vedup loaded LazyVim with an unexpected Neovim version"
  fi
  ! grep -Fq 'exec -- nvim --headless' "$exec_log" || \
    fail "Vedup started LazyVim before rejecting the wrong Neovim version"
  # shellcheck disable=SC2016
  grep -Fq 'mise_exec_config "$MISE_CONFIG_FILE" nvim --headless' "$REPO_ROOT/bin/doctor" || \
    fail "doctor still verifies an ambient Neovim binary"
  pass "explicit pinned Mise execution and non-interactive Neovim synchronization"
}

state_and_resume() {
  local state_home="$TEST_ROOT/state" malicious_marker="$TEST_ROOT/state-code-executed"
  local overlay_home overlay_output interrupted_home commit_home mise_home mise_inventory mise_output unsupported_home unsupported_name rollback_guard_home
  mkdir -p "$state_home/vedup"
  cat > "$state_home/vedup/state.tsv" <<'EOF'
schema	1
status	complete
release	v1.0.0
commit	0000000000000000000000000000000000000000
platform	linux
distro	ubuntu
profile	server
with_aws	1
with_docker	0
with_personal_apps	0
apply_macos_defaults	0
minimal_dock	0
keyboard_shortcuts	0
experimental_macos_defaults	0
change_shell	0
stow_packages	zsh nvim starship tmux scripts
EOF
  XDG_STATE_HOME="$state_home" bash -c '
    set -Eeuo pipefail
    source "$1/lib/state.sh"
    state_load
    [ "$STATE_PROFILE" = server ] && [ "$STATE_WITH_AWS" = 1 ] && [ "$STATE_RELEASE" = v1.0.0 ]
  ' _ "$REPO_ROOT" || fail "valid TSV state did not load"

  sed "s|^release.*|release\\t\\\$(touch $malicious_marker)|" "$state_home/vedup/state.tsv" > "$state_home/vedup/malicious.tsv"
  if XDG_STATE_HOME="$state_home" STATE_TEST_FILE="$state_home/vedup/malicious.tsv" bash -c '
    set -Eeuo pipefail; source "$1/lib/state.sh"; state_load "$STATE_TEST_FILE"
  ' _ "$REPO_ROOT" >/dev/null 2>&1; then
    fail "malformed state was accepted"
  fi
  [ ! -e "$malicious_marker" ] || fail "state data was executed as shell code"

  unsupported_home="$TEST_ROOT/unsupported-state"
  unsupported_name="mac""autosetup"
  mkdir -p "$unsupported_home/$unsupported_name"
  cat > "$unsupported_home/$unsupported_name/install.env" <<'EOF'
PLATFORM=linux
DISTRO=ubuntu
PROFILE=server
WITH_AWS=1
WITH_DOCKER=0
WITH_PERSONAL_APPS=0
APPLY_MACOS_DEFAULTS=0
CHANGE_SHELL=1
STOW_PACKAGES=zsh\ nvim\ starship\ tmux\ scripts
EOF
  XDG_STATE_HOME="$unsupported_home" VEDUP_TEST_INVENTORY_FILE="$VEDUP_TEST_INVENTORY_FILE" bash -c '
    set -Eeuo pipefail
    source "$1/lib/common.sh"
    source "$1/lib/state.sh"
    state_detect_workflow
    [ "$STATE_WORKFLOW" = fresh ] && [ "$STATE_FOUND" = 0 ]
    [ ! -e "$XDG_STATE_HOME/vedup/state.tsv" ]
  ' _ "$REPO_ROOT" || fail "unsupported pre-Vedup state was imported"
  rollback_guard_home="$TEST_ROOT/config-rollback-guard"
  HOME="$rollback_guard_home" REPO_ROOT="$REPO_ROOT" bash -c '
    set -Eeuo pipefail
    source "$REPO_ROOT/lib/config.sh"
    VEDUP_TRANSACTION_DIR="$HOME/.local/state/vedup/transactions/test"
    mkdir -p "$VEDUP_CONFIG_BASE" "$VEDUP_CONFIG_WORKTREE" "$VEDUP_TRANSACTION_DIR"
    printf original > "$VEDUP_CONFIG_BASE/sentinel"
    printf original > "$VEDUP_CONFIG_WORKTREE/sentinel"
    : > "$VEDUP_TRANSACTION_DIR/config-activation.tsv"
    CONFIG_ROLLBACK_ARMED=1
    config_rollback_workspace
    [ -f "$VEDUP_CONFIG_BASE/sentinel" ] && [ -f "$VEDUP_CONFIG_WORKTREE/sentinel" ]
  ' || fail "an unstarted configuration activation could delete the original workspace"

  interrupted_home="$TEST_ROOT/interrupted-state"
  mkdir -p "$interrupted_home/vedup/transactions/20260816T000000Z-1"
  cp "$state_home/vedup/state.tsv" "$interrupted_home/vedup/transactions/20260816T000000Z-1/candidate-state.tsv"
  mkdir -p "$interrupted_home/vedup"
  sed 's/^with_aws.*/with_aws\t0/' "$state_home/vedup/state.tsv" > "$interrupted_home/vedup/state.tsv"
  printf 'keep\tgit\tsystem\texternal\tinstalled\tcompatible\tRetain Git\n' > "$interrupted_home/vedup/resources.tsv"
  cp "$interrupted_home/vedup/resources.tsv" \
    "$interrupted_home/vedup/transactions/20260816T000000Z-1/candidate-resources.tsv"
  printf '2026-08-16T00:00:00Z\tfailed\tpackages\tinjected failure\n' > \
    "$interrupted_home/vedup/transactions/20260816T000000Z-1/journal.tsv"
  XDG_STATE_HOME="$interrupted_home" VEDUP_TEST_INVENTORY_FILE="$VEDUP_TEST_INVENTORY_FILE" bash -c '
    set -Eeuo pipefail
    source "$1/lib/common.sh"
    source "$1/lib/state.sh"
    state_detect_workflow
    [ "$STATE_WORKFLOW" = interrupted ] && [ "$STATE_PROFILE" = server ] && [ "$STATE_WITH_AWS" = 1 ]
  ' _ "$REPO_ROOT" || fail "interrupted candidate choices were not recovered"

  overlay_home="$TEST_ROOT/state-overlay"
  mkdir -p "$overlay_home/vedup"
  sed -e 's/^with_docker.*/with_docker\t1/' -e 's/^change_shell.*/change_shell\t1/' \
    "$state_home/vedup/state.tsv" > "$overlay_home/vedup/state.tsv"
  printf 'keep\tgit\tsystem\texternal\tinstalled\tcompatible\tRetain Git\n' > "$overlay_home/vedup/resources.tsv"
  overlay_output="$(XDG_STATE_HOME="$overlay_home" HOME="$TEST_ROOT/state-overlay-home" \
    VEDUP_TEST_INVENTORY_FILE="$VEDUP_TEST_INVENTORY_FILE" VEDUP_TEST_OS=linux \
    VEDUP_TEST_DISTRO=ubuntu VEDUP_TEST_ARCH=x64 "$REPO_ROOT/bin/setup" \
      --without-aws --dry-run --no-shell-change --no-verify --skip-plugins 2>&1)"
  [[ "$overlay_output" == *"mise-tool:lazydocker"* && "$overlay_output" != *"mise-tool:aws"* ]] || \
    fail "an explicit component override discarded unrelated saved choices"
  [[ "$overlay_output" == *"Leave the login shell unchanged"* ]] || \
    fail "--no-shell-change was overwritten by the saved selection"

  commit_home="$TEST_ROOT/state-commit"
  mkdir -p "$commit_home/vedup/transactions/test"
  cp "$state_home/vedup/state.tsv" "$commit_home/vedup/state.tsv"
  printf 'keep\tgit\tsystem\texternal\tinstalled\tcompatible\tRetain Git\n' > "$commit_home/vedup/resources.tsv"
  sed 's/^with_aws.*/with_aws\t0/' "$state_home/vedup/state.tsv" > \
    "$commit_home/vedup/transactions/test/candidate-state.tsv"
  cp "$commit_home/vedup/resources.tsv" "$commit_home/vedup/transactions/test/candidate-resources.tsv"
  : > "$commit_home/vedup/transactions/test/journal.tsv"
  XDG_STATE_HOME="$commit_home" bash -c '
    set -Eeuo pipefail
    source "$1/lib/state.sh"
    VEDUP_TRANSACTION_DIR="$XDG_STATE_HOME/vedup/transactions/test"
    state_commit_candidate
    state_load
    [ "$STATE_WITH_AWS" = 0 ]
    state_rollback_commit
    state_load
    [ "$STATE_WITH_AWS" = 1 ]
    rm -f "$VEDUP_TRANSACTION_DIR/state-commit.rolled-back"
    state_commit_candidate
    : > "$VEDUP_TRANSACTION_DIR/COMMITTED"
    state_rollback_commit
    state_load
    [ "$STATE_WITH_AWS" = 0 ]
  ' _ "$REPO_ROOT" || fail "live state was not restored after an activation-style rollback"

  mise_home="$TEST_ROOT/state-mise"
  mise_inventory="$TEST_ROOT/state-mise-inventory.tsv"
  mkdir -p "$mise_home/vedup"
  sed 's/^with_aws.*/with_aws\t0/' "$state_home/vedup/state.tsv" > "$mise_home/vedup/state.tsv"
  printf 'install\tmise-tool:node\tmise:node\tvedup-managed\tinstalled\t24.18.0\tPinned Node\n' > "$mise_home/vedup/resources.tsv"
  printf 'command\tmise\ncommand\tnode\n' > "$mise_inventory"
  mise_output="$(XDG_STATE_HOME="$mise_home" HOME="$TEST_ROOT/state-mise-home" \
    VEDUP_TEST_INVENTORY_FILE="$mise_inventory" VEDUP_TEST_OS=linux \
    VEDUP_TEST_DISTRO=ubuntu VEDUP_TEST_ARCH=x64 "$REPO_ROOT/bin/setup" \
      --dry-run --no-shell-change --no-verify --skip-plugins 2>&1)"
  [[ "$mise_output" == *"update     mise-tool:node"* ]] || fail "a missing managed Mise version was inferred from a shim"
  printf 'mise-tool\tnode@24.18.0\n' >> "$mise_inventory"
  mise_output="$(XDG_STATE_HOME="$mise_home" HOME="$TEST_ROOT/state-mise-home" \
    VEDUP_TEST_INVENTORY_FILE="$mise_inventory" VEDUP_TEST_OS=linux \
    VEDUP_TEST_DISTRO=ubuntu VEDUP_TEST_ARCH=x64 "$REPO_ROOT/bin/setup" \
      --dry-run --no-shell-change --no-verify --skip-plugins 2>&1)"
  [[ "$mise_output" == *"keep       mise-tool:node"* ]] || fail "an exact managed Mise version was needlessly updated"
  pass "validated current state, unsupported-state isolation, and interrupted-run detection"
}

release_failure_safety() {
  local fixture="$TEST_ROOT/release-failure" payload archive checksum rendered fake_bin output_home activation_release activation_current activation_applied
  fixture="$TEST_ROOT/release-failure"
  payload="$fixture/payload/vedup-v9.9.9"
  archive="$fixture/incomplete.tar.gz"
  rendered="$fixture/bootstrap"
  fake_bin="$fixture/bin"
  output_home="$fixture/home"
  mkdir -p "$payload" "$fake_bin" "$output_home"
  printf 'incomplete\n' > "$payload/README"
  tar -czf "$archive" -C "$fixture/payload" vedup-v9.9.9
  checksum="$(test_sha256 "$archive")"
  sed -e 's/__VEDUP_RELEASE_REF__/v9.9.9/g' \
    -e 's/__VEDUP_RELEASE_COMMIT__/9999999999999999999999999999999999999999/g' \
    -e "s/__VEDUP_ARCHIVE_SHA256__/$checksum/g" \
    -e 's|__VEDUP_RELEASE_REPOSITORY__|vedprakash2302/Vedup|g' \
    "$REPO_ROOT/bootstrap" > "$rendered"
  cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then output="$2"; shift 2; else shift; fi
done
cp "$VEDUP_FAKE_ARCHIVE" "$output"
EOF
  chmod +x "$fake_bin/curl" "$rendered"
  if HOME="$output_home" VEDUP_FAKE_ARCHIVE="$archive" PATH="$fake_bin:/usr/bin:/bin" "$rendered" >/dev/null 2>&1; then
    fail "an incomplete release archive was accepted"
  fi
  [ ! -e "$output_home/.local/share/vedup/current" ] || fail "failed release extraction changed the active release"
  [ ! -d "$output_home/.local/share/vedup/releases/v9.9.9-999999999999" ] || fail "failed extraction left a completed release"

  activation_release="$fixture/activation/release"
  activation_current="$fixture/activation/current"
  activation_applied="$fixture/activation/applied"
  mkdir -p "$fixture/activation/old"
  cp -R "$REPO_ROOT" "$activation_release"
  ln -s "$fixture/activation/old" "$activation_current"
  VEDUP_ACTIVATION_RELEASE="$activation_release" VEDUP_ACTIVATION_CURRENT="$activation_current" \
    VEDUP_ACTIVATION_APPLIED="$activation_applied" bash -c '
    set -Eeuo pipefail
    set --
    source "$VEDUP_ACTIVATION_RELEASE/bin/setup"
    VEDUP_PENDING_RELEASE="$VEDUP_ACTIVATION_RELEASE"
    VEDUP_CURRENT_LINK="$VEDUP_ACTIVATION_CURRENT"
    VEDUP_APPLIED_LINK="$VEDUP_ACTIVATION_APPLIED"
    VEDUP_TRANSACTION_DIR="$(dirname "$VEDUP_ACTIVATION_CURRENT")/transaction"
    mkdir -p "$VEDUP_TRANSACTION_DIR"
    activate_pending_release
  ' || fail "verified release activation failed"
  [ "$(readlink "$activation_current")" = "$activation_release" ] || fail "current was not atomically switched to the verified release"
  [ "$(readlink "$activation_applied")" = "$activation_release" ] || fail "applied policy was not switched with committed setup"
  pass "checksum-bound release extraction and failure-safe activation"
}

dotfile_failure_rollback() {
  local rollback_home="$TEST_ROOT/rollback-home" fake_bin="$TEST_ROOT/rollback-bin" real_stow
  local doctor_home="$TEST_ROOT/doctor-rollback-home" doctor_repo="$TEST_ROOT/doctor-failure-repo"
  local activation_home="$TEST_ROOT/activation-rollback-home"
  mkdir -p "$rollback_home" "$fake_bin" "$doctor_home" "$activation_home"
  printf 'original-before-failure\n' > "$rollback_home/.zshrc"
  real_stow="$(command -v stow)"
  cat > "$fake_bin/stow" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
arguments=" $* "
if [[ "$arguments" == *" --restow "* && "$arguments" != *" --simulate "* && "$arguments" == *" nvim "* ]]; then
  exit 73
fi
exec "$VEDUP_REAL_STOW" "$@"
EOF
  chmod +x "$fake_bin/stow"
  if HOME="$rollback_home" PATH="$fake_bin:$PATH" VEDUP_REAL_STOW="$real_stow" \
    "$REPO_ROOT/bin/setup" --dotfiles-only --skip-plugins --no-shell-change --no-verify >/dev/null 2>&1; then
    fail "injected Stow failure unexpectedly succeeded"
  fi
  [ ! -L "$rollback_home/.zshrc" ] || fail "failed Stow transaction left a managed link"
  [ "$(sed -n '1p' "$rollback_home/.zshrc")" = original-before-failure ] || fail "failed Stow transaction did not restore the original config"
  [ ! -e "$rollback_home/.local/state/vedup/state.tsv" ] || fail "failed setup committed live state"
  grep -R -Eq $'\t(failed|rolled-back)\ttransaction\t' "$rollback_home/.local/state/vedup/transactions" || \
    fail "failed setup did not persist its transaction journal"

  cp -R "$REPO_ROOT" "$doctor_repo"
  cat > "$doctor_repo/bin/doctor" <<'EOF'
#!/usr/bin/env bash
exit 81
EOF
  chmod +x "$doctor_repo/bin/doctor"
  printf 'original-before-doctor\n' > "$doctor_home/.zshrc"
  if HOME="$doctor_home" "$doctor_repo/bin/setup" --dotfiles-only --skip-plugins \
      --no-shell-change --no-verify >/dev/null 2>&1; then
    fail "an injected post-link doctor failure unexpectedly succeeded"
  fi
  [ ! -L "$doctor_home/.zshrc" ] || fail "post-link doctor failure left the new managed link"
  [ "$(sed -n '1p' "$doctor_home/.zshrc")" = original-before-doctor ] || \
    fail "post-link doctor failure did not restore the previous configuration"

  printf 'original-before-activation\n' > "$activation_home/.zshrc"
  if HOME="$activation_home" VEDUP_PENDING_RELEASE="$TEST_ROOT/not-the-running-release" \
    VEDUP_CURRENT_LINK="$activation_home/.local/share/vedup/current" \
    "$REPO_ROOT/bin/setup" --dotfiles-only --skip-plugins --no-shell-change --no-verify >/dev/null 2>&1; then
    fail "an injected release activation failure unexpectedly succeeded"
  fi
  [ "$(sed -n '1p' "$activation_home/.zshrc")" = original-before-activation ] || \
    fail "activation failure did not restore the prior configuration"
  [ ! -e "$activation_home/.local/state/vedup/state.tsv" ] || \
    fail "activation failure did not roll back newly committed live state"
  if [ -e "$activation_home/.local/bin/vedup" ] || [ -L "$activation_home/.local/bin/vedup" ]; then
    fail "activation failure left a dangling Vedup command"
  fi
  pass "dotfile failure injection and automatic rollback"
}

dotfile_lifecycle() {
  command -v stow >/dev/null 2>&1 || fail "GNU Stow is required for the lifecycle test"
  local test_home="$TEST_ROOT/home" backup_list first_count second_count zsh_output second_output state_hash
  mkdir -p "$test_home"
  printf 'original zsh config\n' > "$test_home/.zshrc"

  HOME="$test_home" "$REPO_ROOT/bin/setup" --dotfiles-only --skip-plugins --no-shell-change --no-verify >/dev/null
  [ -L "$test_home/.zshrc" ] || fail "setup did not link .zshrc"
  backup_list="$test_home/.local/state/vedup/backups.list"
  [ -s "$backup_list" ] || fail "setup did not record its conflict backup"
  first_count="$(wc -l < "$backup_list" | tr -d ' ')"
  state_hash="$(test_sha256 "$test_home/.local/state/vedup/state.tsv")"

  second_output="$(HOME="$test_home" "$REPO_ROOT/bin/setup" --dotfiles-only --skip-plugins --no-shell-change --no-verify 2>&1)"
  [[ "$second_output" == *"already synchronized; no changes were made"* ]] || fail "second safe sync was not a no-op"
  second_count="$(wc -l < "$backup_list" | tr -d ' ')"
  [ "$first_count" = "$second_count" ] || fail "idempotent rerun created a spurious backup"
  [ "$state_hash" = "$(test_sha256 "$test_home/.local/state/vedup/state.tsv")" ] || fail "no-op rerun rewrote state"
  find "$test_home/.local/state/vedup/logs" -type f -name '*.log' | grep -q . || \
    fail "setup did not retain a detailed installation log"

  if command -v zsh >/dev/null 2>&1; then
    zsh_output="$(env HOME="$test_home" ZDOTDIR="$test_home" TERM=xterm-256color zsh -dfc 'cd; source ~/.zshrc' 2>&1)"
    [ -z "$zsh_output" ] || fail "Zsh startup produced output: $zsh_output"
  fi

  HOME="$test_home" "$REPO_ROOT/bin/uninstall" --restore-backup >/dev/null
  [ ! -L "$test_home/.zshrc" ] || fail "uninstall left .zshrc linked"
  [ "$(sed -n '1p' "$test_home/.zshrc")" = 'original zsh config' ] || fail "uninstall did not restore the original .zshrc"
  pass "backup, link, rerun, and restore lifecycle"
}

config_workspace_and_capture() {
  local managed_home="$TEST_ROOT/config-workspace-home" conflict_repo="$TEST_ROOT/config-conflict-repo"
  local capture_source="$TEST_ROOT/capture-source" capture_remote="$TEST_ROOT/capture-remote.git"
  local status_output second_output conflict_output capture_output capture_branch
  mkdir -p "$managed_home"

  HOME="$managed_home" "$REPO_ROOT/bin/setup" --dotfiles-only --skip-plugins --no-shell-change --no-verify >/dev/null
  [ -L "$managed_home/.zshrc" ] || fail "writable workspace setup did not link .zshrc"
  [[ "$(readlink "$managed_home/.zshrc")" == *"/vedup/config/worktree/"* ]] || \
    fail "managed configuration still links directly into an immutable release"
  printf '\n# captured-local-change\n' >> "$managed_home/.zshrc"
  status_output="$(HOME="$managed_home" "$REPO_ROOT/bin/status" 2>&1)"
  [[ "$status_output" == *"local change(s) available to save"* ]] || \
    fail "vedup status did not report local configuration drift"

  second_output="$(HOME="$managed_home" "$REPO_ROOT/bin/setup" --dotfiles-only --skip-plugins \
    --no-shell-change --no-verify 2>&1)"
  [[ "$second_output" == *"already synchronized; no changes were made"* ]] || \
    fail "a local configuration edit made Safe sync mutate the machine"
  grep -Fq '# captured-local-change' "$managed_home/.zshrc" || fail "Safe sync discarded a local configuration edit"

  cp -R "$REPO_ROOT" "$conflict_repo"
  printf '\n# incoming-release-change\n' >> "$conflict_repo/dotfiles/zsh/.zshrc"
  if conflict_output="$(HOME="$managed_home" "$conflict_repo/bin/setup" --dotfiles-only --skip-plugins \
    --no-shell-change --no-verify 2>&1)"; then
    fail "a file changed both locally and upstream was synchronized without review"
  fi
  [[ "$conflict_output" == *"config-workspace"* && "$conflict_output" == *"local configuration"* ]] || \
    fail "configuration conflict did not produce an actionable review"
  grep -Fq '# captured-local-change' "$managed_home/.zshrc" || fail "configuration conflict overwrote local intent"

  printf 'password=do-not-capture\n' > "$managed_home/.local/share/vedup/config/worktree/zsh/.zsh.d/credentials.local"
  printf 'OPENAI_API_KEY=%s%s\n' 'sk-' 'proj-example-value-that-must-never-publish' > \
    "$managed_home/.local/share/vedup/config/worktree/zsh/.zsh.d/cloud.sh"
  capture_output="$(HOME="$managed_home" "$REPO_ROOT/bin/capture" --dry-run --all 2>&1)"
  [[ "$capture_output" == *"EXCLUDED"* && "$capture_output" == *"credentials.local"* ]] || \
    fail "capture did not block a secret-like machine-local file"
  [[ "$capture_output" == *"config"* && "$capture_output" == *"zsh/.zshrc"* ]] || \
    fail "capture did not discover an allowlisted managed configuration edit"
  [[ "$capture_output" == *"EXCLUDED"* && "$capture_output" == *"cloud.sh"* ]] || \
    fail "capture accepted an API key assignment from an otherwise normal module"

  mkdir -p "$capture_source"
  (cd "$REPO_ROOT" && tar --exclude=.git -cf - .) | (cd "$capture_source" && tar -xf -)
  git -C "$capture_source" init -b main --quiet
  git -C "$capture_source" config user.name Vedup
  git -C "$capture_source" config user.email vedup@example.invalid
  git -C "$capture_source" add -A
  [ "$(git -C "$capture_source" ls-files --stage dotfiles/macos/settings/core.sh | awk '{ print $1 }')" = 100755 ] || \
    fail "capture fixture did not retain executable macOS settings"
  git -C "$capture_source" commit --quiet -m baseline
  git clone --bare --quiet "$capture_source" "$capture_remote"
  git -C "$capture_source" remote add origin "$capture_remote"
  git -C "$capture_source" push --quiet -u origin main
  mkdir -p "$managed_home/.cache/vedup/security/gitleaks/8.30.1"
  cat > "$managed_home/.cache/vedup/security/gitleaks/8.30.1/gitleaks" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != version ] || { printf '8.30.1\n'; exit 0; }
exit 0
EOF
  chmod +x "$managed_home/.cache/vedup/security/gitleaks/8.30.1/gitleaks"
  HOME="$managed_home" "$REPO_ROOT/bin/capture" --all --source "$capture_source" >/dev/null
  capture_branch="$(git -C "$capture_source" for-each-ref --format='%(refname:short)' 'refs/heads/save/*' | tail -n 1)"
  if [ -z "$capture_branch" ] || \
    ! git -C "$capture_source" show "$capture_branch:dotfiles/zsh/.zshrc" | grep -Fq '# captured-local-change'; then
    fail "capture did not commit selected configuration into the author checkout"
  fi
  [ "$(git -C "$capture_source" ls-tree "$capture_branch" dotfiles/macos/settings/core.sh | awk '{ print $1 }')" = 100755 ] || \
    fail "capture removed executable permissions from macOS settings"
  pass "writable configuration workspace, conflict preservation, status, and secret-safe capture"
}

run_test syntax syntax_checks
run_test dry-run-matrix dry_run_matrix
run_test interactive-installer interactive_installer
run_test saved-choices saved_application_choices
run_test concise-progress concise_progress
run_test administrator-approval administrator_approval
run_test parallel-and-recovery parallel_and_recovery
run_test zsh-features zsh_features
run_test macos-settings-safety macos_settings_safety
run_test macos-preference-rollback macos_preference_rollback
run_test release-asset release_asset
run_test self-update vedup_self_update
run_test safe-sync-invariants safe_sync_invariants
run_test mise-execution-boundary mise_execution_boundary
run_test state-and-resume state_and_resume
run_test release-failure-safety release_failure_safety
run_test dotfile-failure-rollback dotfile_failure_rollback
run_test dotfile-lifecycle dotfile_lifecycle
if [ "${VEDUP_CAPTURE_VALIDATION:-0}" != 1 ]; then run_test config-workspace-and-capture config_workspace_and_capture; fi
printf '[test] All checks passed. Temporary files: %s\n' "$TEST_ROOT"
