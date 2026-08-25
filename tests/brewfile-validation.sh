#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

if [ "$(uname -s)" != Darwin ]; then
  printf '[test] macOS application provider validation is macOS-only; skipped\n'
  exit 0
fi

# shellcheck disable=SC1091
. "$REPO_ROOT/lib/apps.sh"
apps_manifest_validate

brew_info_with_retry() {
  local kind="$1" token="$2" attempt=1
  while ! HOMEBREW_NO_AUTO_UPDATE=1 brew info "--$kind" "$token" >/dev/null; do
    if [ "$attempt" -ge 3 ]; then
      printf 'Homebrew could not validate %s after %s attempts: %s\n' "$kind" "$attempt" "$token" >&2
      return 1
    fi
    sleep "$((attempt * 2))"
    attempt=$((attempt + 1))
  done
}

while IFS=$'\t' read -r scope provider identifier label _; do
  case "$scope" in ''|'#'*) continue ;; esac
  case "$identifier" in
    */*/*)
      tap="${identifier%/*}"
      token="${identifier##*/}"
      repository="${tap#*/}"
      tap_checkout="$TEST_ROOT/${tap//\//-}"
      if [ ! -d "$tap_checkout/.git" ]; then
        retry=0
        until git clone --quiet --depth 1 "https://github.com/${tap%%/*}/homebrew-$repository.git" "$tap_checkout"; do
          retry=$((retry + 1))
          [ "$retry" -lt 3 ] || { printf 'Unavailable Homebrew tap for %s: %s\n' "$label" "$tap" >&2; exit 1; }
          rm -rf "$tap_checkout"
          sleep 2
        done
      fi
      token_found=0
      case "$provider" in
        formula)
          # Homebrew accepts both the current Formula/ layout and the legacy
          # tap-root layout still used by established formula repositories.
          for provider_dir in "$tap_checkout/Formula" "$tap_checkout/HomebrewFormula" "$tap_checkout"; do
            [ ! -f "$provider_dir/$token.rb" ] || token_found=1
          done
          ;;
        cask) [ ! -f "$tap_checkout/Casks/$token.rb" ] || token_found=1 ;;
        *) printf 'Unsupported third-party provider: %s\n' "$provider" >&2; exit 1 ;;
      esac
      if [ "$token_found" -ne 1 ]; then
        printf 'Tap exists but does not contain the declared %s token for %s: %s\n' "$provider" "$label" "$identifier" >&2
        exit 1
      fi
      continue
      ;;
    */*)
      printf 'Invalid Homebrew manifest identifier: %s\n' "$identifier" >&2
      exit 1
      ;;
  esac
  case "$provider" in
    formula) brew_info_with_retry formula "$identifier" ;;
    cask) brew_info_with_retry cask "$identifier" ;;
    mas) [[ "$identifier" =~ ^[0-9]+$ ]] ;;
  esac
done < "$VEDUP_MACOS_APPS_MANIFEST"

printf '[test] macOS application manifest and official Homebrew tokens are available\n'
