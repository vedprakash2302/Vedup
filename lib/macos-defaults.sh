#!/usr/bin/env bash

macos_log() { [ "${MACOS_LIST_KEYS:-0}" = 1 ] || printf '[macos] %s\n' "$*"; }
macos_warn() { [ "${MACOS_LIST_KEYS:-0}" = 1 ] || printf '[macos] WARN: %s\n' "$*" >&2; }
macos_die() { printf '[macos] ERROR: %s\n' "$*" >&2; exit 1; }

macos_run() {
  if [ "${MACOS_LIST_KEYS:-0}" = 1 ]; then
    if [ "${1:-}" = defaults ] && [ "${2:-}" = -currentHost ] && [ "${3:-}" = write ]; then
      printf 'host\t%s\t%s\n' "$4" "$5"
    elif [ "${1:-}" = defaults ] && [ "${2:-}" = import ]; then
      printf 'domain\t%s\t__entire_domain__\n' "$3"
    fi
    return 0
  fi
  if [ "${MACOS_CHECK_ONLY:-0}" = 1 ]; then
    if [ "${1:-}" = defaults ] && [ "${2:-}" = -currentHost ] && [ "${3:-}" = write ]; then
      current="$(defaults -currentHost read "$4" "$5" 2>/dev/null || true)"
      [ "$current" = "${7:-}" ] && return 0
      exit 3
    elif [ "${1:-}" = defaults ] && [ "${2:-}" = import ]; then
      actual_preferences="$(mktemp "${TMPDIR:-/tmp}/vedup-defaults-actual.XXXXXX")"
      desired_preferences="$(mktemp "${TMPDIR:-/tmp}/vedup-defaults-desired.XXXXXX")"
      actual_canonical="${actual_preferences}.json"
      desired_canonical="${desired_preferences}.json"
      if defaults export "$3" "$actual_preferences" >/dev/null 2>&1 && \
        plutil -convert json -o - "$actual_preferences" 2>/dev/null | jq -S . > "$actual_canonical" && \
        plutil -convert json -o - "$4" 2>/dev/null | jq -S . > "$desired_canonical" && \
        cmp -s "$actual_canonical" "$desired_canonical"; then
        rm -f "$actual_preferences" "$desired_preferences" "$actual_canonical" "$desired_canonical"
        return 0
      fi
      rm -f "$actual_preferences" "$desired_preferences" "$actual_canonical" "$desired_canonical"
      exit 3
    elif [ "${1:-}" = chflags ] && [ "${2:-}" = nohidden ]; then
      /bin/ls -ldO "$3" 2>/dev/null | awk '{ for (i=1; i<=NF; i++) if ($i == "hidden") exit 1 }' && return 0
      exit 3
    fi
    return 0
  fi
  if [ "${MACOS_DRY_RUN:-0}" = 1 ]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

macos_defaults() {
  local domain="$1" key="$2" value_type="$3" desired="${4:-}" current normalized_desired
  if [ "${MACOS_LIST_KEYS:-0}" = 1 ]; then
    printf 'user\t%s\t%s\n' "$domain" "$key"
    return 0
  fi
  if [ "${MACOS_DRY_RUN:-0}" != 1 ] && current="$(defaults read "$domain" "$key" 2>/dev/null)"; then
    normalized_desired="$desired"
    case "$value_type" in
      -bool)
        case "$current" in 1|true|TRUE) current=true ;; 0|false|FALSE) current=false ;; esac
        ;;
      -int) current="${current%.*}"; normalized_desired="${desired%.*}" ;;
      -float) : ;;
    esac
    if [ "$value_type" = -array ] && [ -z "$desired" ]; then
      current="$(printf '%s' "$current" | tr -d '[:space:]')"
      normalized_desired='()'
    fi
    if [ "$current" = "$normalized_desired" ]; then
      macos_log "Already set: $domain $key"
      return 0
    fi
  fi
  [ "${MACOS_CHECK_ONLY:-0}" != 1 ] || exit 3
  macos_run defaults write "$@"
  if [ "${MACOS_DRY_RUN:-0}" != 1 ]; then
    defaults read "$domain" "$key" >/dev/null 2>&1 || \
      macos_die "Could not verify $domain $key after writing it."
  fi
}

macos_major_version() {
  if [ -n "${VEDUP_TEST_MACOS_MAJOR:-}" ]; then
    printf '%s\n' "$VEDUP_TEST_MACOS_MAJOR"
  else
    sw_vers -productVersion | awk -F. '{print $1}'
  fi
}

require_supported_macos_internals() {
  local major
  major="$(macos_major_version)"
  case "$major" in
    14|15|26) ;;
    *)
      [ "${VEDUP_ALLOW_UNTESTED_MACOS:-0}" = 1 ] || \
        macos_die "Undocumented preferences are untested on macOS $major. Set VEDUP_ALLOW_UNTESTED_MACOS=1 to override."
      macos_warn "Applying undocumented preferences on untested macOS $major."
      ;;
  esac
}
