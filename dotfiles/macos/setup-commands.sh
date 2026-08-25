#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DRY_RUN=0
MINIMAL_DOCK=0
KEYBOARD_SHORTCUTS=0
EXPERIMENTAL=0
MACOS_CHECK_ONLY=0
APPLY_CORE=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) MACOS_DRY_RUN=1 ;;
    --minimal-dock) MINIMAL_DOCK=1 ;;
    --keyboard-shortcuts) KEYBOARD_SHORTCUTS=1 ;;
    --experimental) EXPERIMENTAL=1 ;;
    --check) MACOS_CHECK_ONLY=1 ;;
    --advanced-only) APPLY_CORE=0 ;;
    *) printf 'Unknown macOS settings option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
export MACOS_DRY_RUN
export MACOS_CHECK_ONLY

if [ "${VEDUP_TEST_OS:-}" != macos ] && [ "$(uname -s)" != Darwin ]; then
  printf 'macOS settings can only be applied on macOS.\n' >&2
  exit 1
fi

list_touched_keys() {
  [ "$APPLY_CORE" = 0 ] || MACOS_LIST_KEYS=1 "$SCRIPT_DIR/settings/core.sh"
  [ "$MINIMAL_DOCK" = 1 ] && MACOS_LIST_KEYS=1 "$SCRIPT_DIR/settings/minimal-dock.sh"
  [ "$KEYBOARD_SHORTCUTS" = 1 ] && MACOS_LIST_KEYS=1 "$SCRIPT_DIR/settings/keyboard-shortcuts.sh"
  [ "$EXPERIMENTAL" = 1 ] && MACOS_LIST_KEYS=1 "$SCRIPT_DIR/settings/experimental.sh"
  return 0
}

if [ "$MACOS_CHECK_ONLY" = 1 ]; then
  [ "$APPLY_CORE" = 0 ] || "$SCRIPT_DIR/settings/core.sh"
  [ "$MINIMAL_DOCK" = 1 ] && "$SCRIPT_DIR/settings/minimal-dock.sh"
  [ "$KEYBOARD_SHORTCUTS" = 1 ] && "$SCRIPT_DIR/settings/keyboard-shortcuts.sh"
  [ "$EXPERIMENTAL" = 1 ] && "$SCRIPT_DIR/settings/experimental.sh"
  exit 0
elif [ "$MACOS_DRY_RUN" = 1 ]; then
  printf '[dry-run] %q --keys-file <touched-keys>\n' "$SCRIPT_DIR/../../bin/macos-backup"
else
  keys_file="$(mktemp "${TMPDIR:-/tmp}/vedup-macos-keys.XXXXXX")"
  list_touched_keys | awk '!seen[$0]++' > "$keys_file"
  backup_dir="$("$SCRIPT_DIR/../../bin/macos-backup" --keys-file "$keys_file")"
  rm -f "$keys_file"
  if [ -n "${VEDUP_MACOS_ROLLBACK_FILE:-}" ]; then printf '%s\n' "$backup_dir" > "$VEDUP_MACOS_ROLLBACK_FILE"; fi
  rollback_preferences() {
    printf 'macOS preference application failed; restoring the pre-run snapshot.\n' >&2
    "$SCRIPT_DIR/../../bin/macos-restore" "$backup_dir" || \
      printf 'Automatic restore failed. Recovery snapshot: %s\n' "$backup_dir" >&2
    [ -z "${VEDUP_MACOS_ROLLBACK_FILE:-}" ] || rm -f "$VEDUP_MACOS_ROLLBACK_FILE"
  }
  trap rollback_preferences ERR
fi

[ "$APPLY_CORE" = 0 ] || "$SCRIPT_DIR/settings/core.sh"
[ "$MINIMAL_DOCK" = 1 ] && "$SCRIPT_DIR/settings/minimal-dock.sh"
[ "$KEYBOARD_SHORTCUTS" = 1 ] && "$SCRIPT_DIR/settings/keyboard-shortcuts.sh"
[ "$EXPERIMENTAL" = 1 ] && "$SCRIPT_DIR/settings/experimental.sh"

if [ "$MACOS_DRY_RUN" != 1 ]; then
  if [ "$KEYBOARD_SHORTCUTS" = 1 ] && [ -x /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings ]; then
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u || true
  fi
  killall Dock 2>/dev/null || true
  killall Finder 2>/dev/null || true
  killall SystemUIServer 2>/dev/null || true
  trap - ERR
fi
