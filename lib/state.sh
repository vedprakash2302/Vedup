#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2119,SC2120

# Vedup state is data, never shell code. Every file in this directory is a
# validated TSV document so a corrupted or malicious state file cannot execute.

VEDUP_STATE_DIR="${VEDUP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vedup}"
VEDUP_STATE_FILE="$VEDUP_STATE_DIR/state.tsv"
VEDUP_LIVE_RESOURCES_FILE="$VEDUP_STATE_DIR/resources.tsv"
VEDUP_RESOURCES_FILE="${VEDUP_RESOURCES_CANDIDATE:-$VEDUP_LIVE_RESOURCES_FILE}"
VEDUP_LIVE_CHOICES_FILE="$VEDUP_STATE_DIR/choices.tsv"
VEDUP_CHOICES_FILE="${VEDUP_CHOICES_CANDIDATE:-${VEDUP_CHOICES_FILE:-$VEDUP_LIVE_CHOICES_FILE}}"
VEDUP_TRANSACTIONS_DIR="$VEDUP_STATE_DIR/transactions"

STATE_FOUND=0
STATE_STATUS=""
STATE_RELEASE=""
STATE_COMMIT=""
STATE_PLATFORM=""
STATE_DISTRO=""
STATE_PROFILE=""
STATE_WITH_AWS=0
STATE_WITH_DOCKER=0
STATE_WITH_PERSONAL_APPS=0
STATE_APPLY_MACOS_DEFAULTS=0
STATE_MINIMAL_DOCK=0
STATE_KEYBOARD_SHORTCUTS=0
STATE_EXPERIMENTAL_MACOS_DEFAULTS=0
STATE_CHANGE_SHELL=0
STATE_STOW_PACKAGES=""
STATE_WORKFLOW="fresh"
VEDUP_TRANSACTION_ID=""
VEDUP_TRANSACTION_DIR=""
VEDUP_INTERRUPTED_TRANSACTION_DIR=""
STATE_COMMIT_ROLLBACK_ARMED=0

state_valid_scalar() {
  [[ "$1" != *$'\t'* && "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

state_valid_bool() {
  [[ "$1" == "0" || "$1" == "1" ]]
}

state_assign() {
  local key="$1" value="$2"
  state_valid_scalar "$value" || return 1
  case "$key" in
    schema) [[ "$value" == "1" ]] || return 1 ;;
    status) [[ "$value" == "complete" || "$value" == "pending" ]] || return 1; STATE_STATUS="$value" ;;
    release) [[ "$value" == development || "$value" =~ ^v[0-9A-Za-z._+-]+$ ]] || return 1; STATE_RELEASE="$value" ;;
    commit) [[ "$value" == unknown || "$value" =~ ^[0-9a-f]{7,40}$ ]] || return 1; STATE_COMMIT="$value" ;;
    platform) [[ "$value" == "macos" || "$value" == "linux" ]] || return 1; STATE_PLATFORM="$value" ;;
    distro) [[ "$value" =~ ^[A-Za-z0-9._+-]*$ ]] || return 1; STATE_DISTRO="$value" ;;
    profile) [[ "$value" == "server" || "$value" == "workstation" ]] || return 1; STATE_PROFILE="$value" ;;
    with_aws) state_valid_bool "$value" || return 1; STATE_WITH_AWS="$value" ;;
    with_docker) state_valid_bool "$value" || return 1; STATE_WITH_DOCKER="$value" ;;
    with_personal_apps) state_valid_bool "$value" || return 1; STATE_WITH_PERSONAL_APPS="$value" ;;
    apply_macos_defaults) state_valid_bool "$value" || return 1; STATE_APPLY_MACOS_DEFAULTS="$value" ;;
    minimal_dock) state_valid_bool "$value" || return 1; STATE_MINIMAL_DOCK="$value" ;;
    keyboard_shortcuts) state_valid_bool "$value" || return 1; STATE_KEYBOARD_SHORTCUTS="$value" ;;
    experimental_macos_defaults) state_valid_bool "$value" || return 1; STATE_EXPERIMENTAL_MACOS_DEFAULTS="$value" ;;
    apply_minimal_dock) state_valid_bool "$value" || return 1; STATE_MINIMAL_DOCK="$value" ;;
    apply_keyboard_remap|apply_keyboard_shortcuts) state_valid_bool "$value" || return 1; STATE_KEYBOARD_SHORTCUTS="$value" ;;
    apply_open_command) state_valid_bool "$value" || return 1 ;;
    change_shell) state_valid_bool "$value" || return 1; STATE_CHANGE_SHELL="$value" ;;
    stow_packages)
      [[ "$value" =~ ^[a-z0-9._+-]+([[:space:]][a-z0-9._+-]+)*$ ]] || return 1
      local package
      for package in $value; do
        case "$package" in zsh|nvim|starship|tmux|scripts|aerospace|ghostty|cursor) ;; *) return 1 ;; esac
      done
      STATE_STOW_PACKAGES="$value"
      ;;
    *) return 1 ;;
  esac
}

state_load() {
  local file="${1:-$VEDUP_STATE_FILE}" key value extra seen="" required
  STATE_FOUND=0
  STATE_STATUS="" STATE_RELEASE="" STATE_COMMIT="" STATE_PLATFORM="" STATE_DISTRO="" STATE_PROFILE=""
  STATE_WITH_AWS=0 STATE_WITH_DOCKER=0 STATE_WITH_PERSONAL_APPS=0 STATE_APPLY_MACOS_DEFAULTS=0
  STATE_MINIMAL_DOCK=0 STATE_KEYBOARD_SHORTCUTS=0 STATE_EXPERIMENTAL_MACOS_DEFAULTS=0 STATE_CHANGE_SHELL=0
  STATE_STOW_PACKAGES=""
  [[ -f "$file" ]] || return 1
  while IFS=$'\t' read -r key value extra || [[ -n "$key$value$extra" ]]; do
    [[ -n "$key" && -z "$extra" ]] || return 2
    case " $seen " in *" $key "*) return 2 ;; esac
    state_assign "$key" "$value" || return 2
    seen="$seen $key"
  done < "$file"
  for required in schema status release commit platform distro profile with_aws with_docker with_personal_apps \
    apply_macos_defaults minimal_dock keyboard_shortcuts experimental_macos_defaults change_shell stow_packages; do
    case " $seen " in *" $required "*) ;; *) return 2 ;; esac
  done
  STATE_FOUND=1
  return 0
}

state_find_interrupted() {
  local journal="" candidate last_status
  [[ -d "$VEDUP_TRANSACTIONS_DIR" ]] || return 1
  for candidate in "$VEDUP_TRANSACTIONS_DIR"/*/journal.tsv; do
    [ -f "$candidate" ] || continue
    if [ -z "$journal" ] || [ "$candidate" -nt "$journal" ]; then journal="$candidate"; fi
  done
  [ -n "$journal" ] || return 1
  last_status="$(tail -n 1 "$journal" | awk -F '\t' '{print $2}')"
  if [[ "$last_status" != complete && "$last_status" != rolled-back ]]; then
    VEDUP_INTERRUPTED_TRANSACTION_DIR="$(dirname "$journal")"
    return 0
  fi
  return 1
}

state_validate_resources() {
  local file="${1:-$VEDUP_RESOURCES_FILE}" action id provider owner current desired description count=0
  [ -r "$file" ] || return 1
  while IFS=$'\t' read -r action id provider owner current desired description; do
    [[ "$action" =~ ^(install|update|keep|configure|review|conflict)$ ]] || return 1
    [[ "$id" =~ ^[A-Za-z0-9._:+/-]+$ && "$provider" =~ ^[A-Za-z0-9._:+/-]+$ ]] || return 1
    [[ "$owner" =~ ^(vedup-managed|external|unmanaged-conflict)$ ]] || return 1
    [ -n "$current" ] && [ -n "$desired" ] && [ -n "$description" ] || return 1
    count=$((count + 1))
  done < "$file"
  [ "$count" -gt 0 ]
}

state_detect_workflow() {
  if state_find_interrupted; then
    state_load "$VEDUP_INTERRUPTED_TRANSACTION_DIR/candidate-state.tsv" 2>/dev/null || \
      state_load "$VEDUP_STATE_FILE" 2>/dev/null || true
    if state_validate_resources "$VEDUP_INTERRUPTED_TRANSACTION_DIR/candidate-resources.tsv" 2>/dev/null; then
      VEDUP_RESOURCES_FILE="$VEDUP_INTERRUPTED_TRANSACTION_DIR/candidate-resources.tsv"
    fi
    if type choices_validate_file >/dev/null 2>&1 && \
      choices_validate_file "$VEDUP_INTERRUPTED_TRANSACTION_DIR/candidate-choices.tsv" 2>/dev/null; then
      VEDUP_CHOICES_FILE="$VEDUP_INTERRUPTED_TRANSACTION_DIR/candidate-choices.tsv"
    fi
    STATE_WORKFLOW="interrupted"
  elif state_load "$VEDUP_STATE_FILE" 2>/dev/null; then
    if state_validate_resources "$VEDUP_LIVE_RESOURCES_FILE" 2>/dev/null; then
      VEDUP_RESOURCES_FILE="$VEDUP_LIVE_RESOURCES_FILE"
    fi
    STATE_WORKFLOW="managed"
  elif type inventory_machine_has_baseline >/dev/null 2>&1 && inventory_machine_has_baseline; then
    STATE_WORKFLOW="existing"
  else
    STATE_WORKFLOW="fresh"
  fi
}

state_begin_transaction() {
  local now
  now="$(date -u +%Y%m%dT%H%M%SZ)"
  VEDUP_TRANSACTION_ID="${now}-$$"
  VEDUP_TRANSACTION_DIR="$VEDUP_TRANSACTIONS_DIR/$VEDUP_TRANSACTION_ID"
  mkdir -p "$VEDUP_TRANSACTION_DIR"
  : > "$VEDUP_TRANSACTION_DIR/journal.tsv"
  state_journal transaction running "Vedup synchronization started"
}

state_journal() {
  local stage="$1" status="$2" detail="${3:-}"
  [[ -n "$VEDUP_TRANSACTION_DIR" ]] || return 0
  detail="${detail//$'\t'/ }"
  detail="${detail//$'\n'/ }"
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" "$stage" "$detail" >> "$VEDUP_TRANSACTION_DIR/journal.tsv"
}

state_write_candidate() {
  local candidate="$VEDUP_TRANSACTION_DIR/candidate-state.tsv" status="${1:-pending}"
  [ "$status" = pending ] || [ "$status" = complete ] || return 1
  [[ -n "$VEDUP_TRANSACTION_DIR" ]] || return 1
  {
    printf 'schema\t1\nstatus\t%s\n' "$status"
    printf 'release\t%s\n' "${VEDUP_RELEASE_REF:-development}"
    printf 'commit\t%s\n' "${VEDUP_RELEASE_COMMIT:-unknown}"
    printf 'platform\t%s\ndistro\t%s\nprofile\t%s\n' "$OS" "$DISTRO" "$PROFILE"
    printf 'with_aws\t%s\nwith_docker\t%s\nwith_personal_apps\t%s\n' "$WITH_AWS" "$WITH_DOCKER" "$WITH_PERSONAL_APPS"
    printf 'apply_macos_defaults\t%s\nminimal_dock\t%s\nkeyboard_shortcuts\t%s\nexperimental_macos_defaults\t%s\n' \
      "$APPLY_MACOS_DEFAULTS" "$MINIMAL_DOCK" "$KEYBOARD_SHORTCUTS" "$EXPERIMENTAL_MACOS_DEFAULTS"
    printf 'change_shell\t%s\nstow_packages\t%s\n' "$CHANGE_SHELL" "${STOW_PACKAGES[*]}"
  } > "$candidate"
  state_load "$candidate" >/dev/null || return 1
  if [[ -n "${PLAN_FILE:-}" && -f "$PLAN_FILE" ]]; then
    cp "$PLAN_FILE" "$VEDUP_TRANSACTION_DIR/candidate-resources.tsv"
  fi
  if type choices_write_file >/dev/null 2>&1; then
    choices_write_file "$VEDUP_TRANSACTION_DIR/candidate-choices.tsv"
  fi
}

state_commit_candidate() {
  local candidate="$VEDUP_TRANSACTION_DIR/candidate-state.tsv"
  local resources="$VEDUP_TRANSACTION_DIR/candidate-resources.tsv"
  local choices="$VEDUP_TRANSACTION_DIR/candidate-choices.tsv"
  local state_tmp="$VEDUP_STATE_DIR/.state.tsv.$$" resources_tmp="$VEDUP_STATE_DIR/.resources.tsv.$$" choices_tmp="$VEDUP_STATE_DIR/.choices.tsv.$$"
  [[ -f "$candidate" && -f "$resources" ]] || return 1
  state_load "$candidate" >/dev/null || return 1
  state_validate_resources "$resources" || return 1
  if type choices_validate_file >/dev/null 2>&1; then choices_validate_file "$choices" || return 1; fi
  mkdir -p "$VEDUP_STATE_DIR"
  : > "$VEDUP_TRANSACTION_DIR/state-commit.armed"
  STATE_COMMIT_ROLLBACK_ARMED=1
  if [ -f "$VEDUP_STATE_FILE" ]; then cp "$VEDUP_STATE_FILE" "$VEDUP_TRANSACTION_DIR/previous-state.tsv"
  else : > "$VEDUP_TRANSACTION_DIR/previous-state.absent"; fi
  if [ -f "$VEDUP_LIVE_RESOURCES_FILE" ]; then cp "$VEDUP_LIVE_RESOURCES_FILE" "$VEDUP_TRANSACTION_DIR/previous-resources.tsv"
  else : > "$VEDUP_TRANSACTION_DIR/previous-resources.absent"; fi
  if [ -f "$VEDUP_LIVE_CHOICES_FILE" ]; then cp "$VEDUP_LIVE_CHOICES_FILE" "$VEDUP_TRANSACTION_DIR/previous-choices.tsv"
  else : > "$VEDUP_TRANSACTION_DIR/previous-choices.absent"; fi
  cp "$candidate" "$state_tmp"
  cp "$resources" "$resources_tmp"
  [ ! -f "$choices" ] || cp "$choices" "$choices_tmp"
  if ! mv "$resources_tmp" "$VEDUP_LIVE_RESOURCES_FILE"; then
    state_rollback_commit
    return 1
  fi
  if [ -f "$choices_tmp" ] && ! mv "$choices_tmp" "$VEDUP_LIVE_CHOICES_FILE"; then
    state_rollback_commit
    return 1
  fi
  if ! mv "$state_tmp" "$VEDUP_STATE_FILE"; then
    state_rollback_commit
    return 1
  fi
  state_journal state committed "Validated candidate state installed; release activation is pending"
}

state_rollback_commit() {
  local transaction="${1:-$VEDUP_TRANSACTION_DIR}" restore_tmp
  [ -n "$transaction" ] || return 0
  [ ! -f "$transaction/COMMITTED" ] || return 0
  [ ! -f "$transaction/state-commit.rolled-back" ] || return 0
  mkdir -p "$VEDUP_STATE_DIR"
  if [ -f "$transaction/previous-state.tsv" ]; then
    restore_tmp="$VEDUP_STATE_DIR/.state.restore.$$"
    cp "$transaction/previous-state.tsv" "$restore_tmp" && mv "$restore_tmp" "$VEDUP_STATE_FILE"
  elif [ -f "$transaction/previous-state.absent" ]; then
    rm -f "$VEDUP_STATE_FILE"
  fi
  if [ -f "$transaction/previous-resources.tsv" ]; then
    restore_tmp="$VEDUP_STATE_DIR/.resources.restore.$$"
    cp "$transaction/previous-resources.tsv" "$restore_tmp" && mv "$restore_tmp" "$VEDUP_LIVE_RESOURCES_FILE"
  elif [ -f "$transaction/previous-resources.absent" ]; then
    rm -f "$VEDUP_LIVE_RESOURCES_FILE"
  fi
  if [ -f "$transaction/previous-choices.tsv" ]; then
    restore_tmp="$VEDUP_STATE_DIR/.choices.restore.$$"
    cp "$transaction/previous-choices.tsv" "$restore_tmp" && mv "$restore_tmp" "$VEDUP_LIVE_CHOICES_FILE"
  elif [ -f "$transaction/previous-choices.absent" ]; then
    rm -f "$VEDUP_LIVE_CHOICES_FILE"
  fi
  rm -f "$VEDUP_STATE_DIR/.state.tsv.$$" "$VEDUP_STATE_DIR/.resources.tsv.$$" "$VEDUP_STATE_DIR/.choices.tsv.$$"
  : > "$transaction/state-commit.rolled-back"
  STATE_COMMIT_ROLLBACK_ARMED=0
  state_journal state rolled-back "Live state restored because release activation failed"
}

state_transaction_is_committed() {
  [ -n "${VEDUP_TRANSACTION_DIR:-}" ] && [ -f "$VEDUP_TRANSACTION_DIR/COMMITTED" ]
}

state_complete_transaction() {
  local temporary="$VEDUP_TRANSACTION_DIR/.COMMITTED.$$"
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$temporary"
  mv "$temporary" "$VEDUP_TRANSACTION_DIR/COMMITTED"
  state_journal transaction complete "State committed and release activated after doctor"
  STATE_COMMIT_ROLLBACK_ARMED=0
}

state_resource_owner() {
  local resource="$1" action id provider owner current desired description candidate
  state_validate_resources "$VEDUP_RESOURCES_FILE" || return 1
  while IFS=$'\t' read -r action id provider owner current desired description; do
    candidate="$id"
    [ "$candidate" = "$resource" ] || [ "$candidate" = "retained:$resource" ] || continue
    printf '%s' "$owner"
    return 0
  done < "$VEDUP_RESOURCES_FILE"
  return 1
}

state_resource_desired() {
  local resource="$1" action id provider owner current desired description candidate
  state_validate_resources "$VEDUP_RESOURCES_FILE" || return 1
  while IFS=$'\t' read -r action id provider owner current desired description; do
    candidate="$id"
    [ "$candidate" = "$resource" ] || [ "$candidate" = "retained:$resource" ] || continue
    printf '%s' "$desired"
    return 0
  done < "$VEDUP_RESOURCES_FILE"
  return 1
}
