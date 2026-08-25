#!/usr/bin/env bash
# shellcheck disable=SC2016

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  SETUP_GREEN='\033[38;5;42m' SETUP_YELLOW='\033[38;5;214m' SETUP_RED='\033[38;5;196m'
  SETUP_CYAN='\033[38;5;86m' SETUP_PURPLE='\033[38;5;99m'
  SETUP_DIM='\033[38;5;245m' SETUP_BOLD='\033[1m' SETUP_RESET='\033[0m'
else
  SETUP_GREEN='' SETUP_YELLOW='' SETUP_RED='' SETUP_CYAN='' SETUP_PURPLE=''
  SETUP_DIM='' SETUP_BOLD='' SETUP_RESET=''
fi

log() { printf '%b[setup]%b %s\n' "$SETUP_GREEN" "$SETUP_RESET" "$*"; }
warn() { printf '%b[setup] WARN:%b %s\n' "$SETUP_YELLOW" "$SETUP_RESET" "$*" >&2; }
die() {
  local was_compact="${PROGRESS_COMPACT:-0}"
  [ "$was_compact" != 1 ] || progress_restore_terminal
  printf '%b[setup] ERROR:%b %s\n' "$SETUP_RED" "$SETUP_RESET" "$*" >&2
  if [ "$was_compact" = 1 ] && [ -n "${SETUP_LOG_FILE:-}" ]; then
    printf 'Detailed log: %s\n' "$SETUP_LOG_FILE" >&2
  fi
  exit 1
}
has() { command -v "$1" >/dev/null 2>&1; }

vedup_is_wsl() {
  [ "${VEDUP_TEST_WSL:-0}" = 1 ] || [ -n "${WSL_INTEROP:-}" ] ||
    grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null
}

vedup_repository() {
  local repository="${VEDUP_REPOSITORY:-}"
  if [ -z "$repository" ]; then
    [ -r "$REPO_ROOT/repository.env" ] || { warn "Vedup repository metadata is unavailable."; return 1; }
    # shellcheck disable=SC1091
    . "$REPO_ROOT/repository.env"
    repository="${VEDUP_DEFAULT_REPOSITORY:-}"
  fi
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    warn "Vedup repository metadata is invalid."
    return 1
  }
  printf '%s\n' "$repository"
}

mise_binary() {
  if [ -x "$HOME/.local/bin/mise" ]; then
    printf '%s\n' "$HOME/.local/bin/mise"
  else
    command -v mise
  fi
}

# Execute a managed tool against one explicit immutable Vedup configuration.
# This prevents an older system binary or an unrelated project config from
# being selected while Vedup is planning, configuring, or verifying a machine.
mise_exec_config() {
  local config="$1" mise_bin
  shift
  [ -r "$config" ] || { warn "Mise configuration is unavailable: $config"; return 1; }
  mise_bin="$(mise_binary)" || { warn "Mise is unavailable."; return 1; }
  env MISE_CONFIG_FILE="$config" \
    MISE_EXEC_AUTO_INSTALL=false \
    MISE_NOT_FOUND_AUTO_INSTALL=false \
    MISE_NOT_FOUND_SYSTEM_FALLBACK=false \
    "$mise_bin" exec -- "$@"
}

mise_trust_config() {
  local config="$1" mise_bin
  [ -r "$config" ] || { warn "Mise configuration is unavailable: $config"; return 1; }
  mise_bin="$(mise_binary)" || { warn "Mise is unavailable."; return 1; }
  "$mise_bin" trust "$config"
}

vedup_launcher_is_managed() {
  local target="$1" link
  if [ -L "$target" ]; then
    link="$(readlink "$target")"
    case "$link" in
      */vedup/releases/*/bin/vedup|*/vedup/current/bin/vedup) return 0 ;;
    esac
    return 1
  fi
  [ -f "$target" ] && grep -Fqx '# vedup-managed-launcher-v2' "$target" 2>/dev/null
}

vedup_install_launcher() {
  local target="${1:-$HOME/.local/bin/vedup}" temporary
  mkdir -p "$(dirname "$target")"
  temporary="$(dirname "$target")/.vedup-launcher.new.$$"
  {
    printf '%s\n' '#!/usr/bin/env bash' '# vedup-managed-launcher-v2' '' 'set -Eeuo pipefail'
    printf '%s\n' 'current="${XDG_DATA_HOME:-$HOME/.local/share}/vedup/current"'
    printf '%s\n' 'entry="$current/bin/vedup"'
    printf '%s\n' '[ -x "$entry" ] || { printf '\''Vedup is incomplete: %s is unavailable. Rerun the Vedup bootstrap.\n'\'' "$entry" >&2; exit 1; }'
    printf '%s\n' 'exec "$entry" "$@"'
  } > "$temporary"
  chmod 0755 "$temporary"
  mv "$temporary" "$target"
}

# Hermetic tests provide a TSV inventory instead of observing the host package
# database. Production runs never set VEDUP_TEST_INVENTORY_FILE.
inventory_fixture_has() {
  local category="$1" name="$2"
  [ -n "${VEDUP_TEST_INVENTORY_FILE:-}" ] || return 2
  [ -r "$VEDUP_TEST_INVENTORY_FILE" ] || return 1
  awk -F '\t' -v category="$category" -v name="$name" \
    '$1 == category && $2 == name { found=1 } END { exit !found }' "$VEDUP_TEST_INVENTORY_FILE"
}

inventory_command_exists() {
  local fixture_status
  if inventory_fixture_has command "$1"; then return 0; else fixture_status="$?"; fi
  [ "$fixture_status" != 1 ] || return 1
  has "$1"
}

inventory_package_installed() {
  local provider="$1" package="$2" fixture_status
  if inventory_fixture_has "package:$provider" "$package"; then return 0; else fixture_status="$?"; fi
  if [ "$fixture_status" = 1 ]; then
    if [ "$provider" = amazon ] && [ "$package" = curl ]; then
      inventory_command_exists curl
      return
    fi
    return 1
  fi
  case "$provider" in
    ubuntu) dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed' ;;
    amazon)
      if rpm -q "$package" >/dev/null 2>&1; then
        return 0
      fi
      # Amazon Linux 2023 intentionally ships curl-minimal, which provides a
      # compatible curl command but conflicts with the full curl RPM.
      [ "$package" = curl ] && inventory_command_exists curl
      ;;
    formula) brew list --formula "${package##*/}" >/dev/null 2>&1 ;;
    cask) brew list --cask "${package##*/}" >/dev/null 2>&1 ;;
    mas) mas list 2>/dev/null | awk '{print $1}' | grep -Fxq "$package" ;;
    *) return 1 ;;
  esac
}

inventory_machine_has_baseline() {
  if [ -n "${VEDUP_TEST_INVENTORY_FILE:-}" ]; then
    inventory_command_exists git || inventory_command_exists brew || inventory_command_exists mise
  else
    has git || has brew || has mise
  fi
}

setup_lock_release() {
  [ -n "${SETUP_LOCK_DIR:-}" ] || return 0
  rm -f -- "$SETUP_LOCK_DIR/pid" 2>/dev/null || true
  rmdir -- "$SETUP_LOCK_DIR" 2>/dev/null || true
  SETUP_LOCK_DIR=""
}

setup_cleanup() {
  local exit_code="$?" macos_backup_path transaction_committed=0
  trap - EXIT INT TERM
  set +e
  progress_stop_activity
  if type plan_cleanup >/dev/null 2>&1; then plan_cleanup; fi
  if [ "$exit_code" -ne 0 ] && [ "${SETUP_SUCCESS:-0}" != 1 ]; then
    if type state_transaction_is_committed >/dev/null 2>&1 && state_transaction_is_committed; then transaction_committed=1; fi
    if [ "$transaction_committed" = 1 ]; then
      warn "Synchronization committed successfully; cleanup was interrupted and will finish on the next Vedup run."
    else
      if type dotfiles_rollback >/dev/null 2>&1; then dotfiles_rollback; fi
      if type config_rollback_workspace >/dev/null 2>&1; then config_rollback_workspace; fi
      if type plugins_rollback >/dev/null 2>&1; then plugins_rollback; fi
      if type vedup_command_rollback >/dev/null 2>&1; then vedup_command_rollback; fi
      if type release_pointers_rollback >/dev/null 2>&1; then release_pointers_rollback; fi
      if type state_rollback_commit >/dev/null 2>&1 && [ "${STATE_COMMIT_ROLLBACK_ARMED:-0}" = 1 ]; then state_rollback_commit; fi
      if [ -r "${VEDUP_MACOS_ROLLBACK_FILE:-}" ]; then
        macos_backup_path="$(sed -n '1p' "$VEDUP_MACOS_ROLLBACK_FILE")"
        case "$macos_backup_path" in
          "${VEDUP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vedup}"/macos-preferences/*)
            warn "Restoring macOS preferences after the interrupted synchronization."
            "$REPO_ROOT/bin/macos-restore" "$macos_backup_path" || true
            ;;
        esac
        rm -f "$VEDUP_MACOS_ROLLBACK_FILE"
      fi
      if type state_journal >/dev/null 2>&1 && [ -n "${VEDUP_TRANSACTION_DIR:-}" ]; then
        state_journal transaction rolled-back "Setup exited with status $exit_code; reversible changes restored"
      fi
    fi
  fi
  sudo_release
  setup_lock_release
  return "$exit_code"
}

version_at_least() {
  local actual="$1" required="$2"
  awk -v actual="$actual" -v required="$required" 'BEGIN {
    split(actual, a, /[^0-9]+/); split(required, r, /[^0-9]+/)
    for (i=1; i<=4; i++) {
      av=a[i]+0; rv=r[i]+0
      if (av > rv) exit 0
      if (av < rv) exit 1
    }
    exit 0
  }'
}

setup_lock_acquire() {
  local state_dir existing_pid
  [ "${DRY_RUN:-0}" != 1 ] || return 0
  SETUP_SUCCESS=0
  state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/vedup"
  SETUP_LOCK_DIR="$state_dir/setup.lock"
  mkdir -p "$state_dir"

  if ! mkdir "$SETUP_LOCK_DIR" 2>/dev/null; then
    existing_pid="$(sed -n '1p' "$SETUP_LOCK_DIR/pid" 2>/dev/null || true)"
    case "$existing_pid" in
      ''|*[!0-9]*) ;;
      *)
        if kill -0 "$existing_pid" 2>/dev/null; then
          die "Another Vedup setup is already running for this account (PID $existing_pid)."
        fi
        ;;
    esac
    rm -f -- "$SETUP_LOCK_DIR/pid" 2>/dev/null || true
    rmdir -- "$SETUP_LOCK_DIR" 2>/dev/null || \
      die "Cannot recover stale setup lock: $SETUP_LOCK_DIR"
    mkdir "$SETUP_LOCK_DIR" || die "Cannot acquire setup lock: $SETUP_LOCK_DIR"
  fi

  printf '%s\n' "$$" > "$SETUP_LOCK_DIR/pid"
  trap setup_cleanup EXIT
  trap 'exit 130' INT TERM
}

sudo_release() {
  [ -n "${SUDO_KEEPALIVE_PID:-}" ] || return 0
  kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  SUDO_KEEPALIVE_PID=""
}

sudo_acquire() {
  SUDO_KEEPALIVE_PID=""
  [ "${DRY_RUN:-0}" != 1 ] || return 0
  [ "$(id -u)" -ne 0 ] || return 0
  has sudo || die "Administrator access is required, but sudo is not installed."

  printf '\n%bAdministrator approval%b\n' "$SETUP_BOLD" "$SETUP_RESET"
  if sudo -n true >/dev/null 2>&1; then
    printf '%b✓%b This account already has administrator access; no password is needed.\n' \
      "$SETUP_GREEN" "$SETUP_RESET"
  else
    printf 'Vedup asks once before installation and keeps this temporary approval active.\n'
    printf 'Your password is handled by sudo and is never read or stored by Vedup.\n\n'
    sudo -v || die "Administrator approval was not granted."
    printf '%b✓%b Administrator approval ready.\n' "$SETUP_GREEN" "$SETUP_RESET"
  fi

  (
    trap - ERR
    set +e
    while :; do
      sleep 50
      sudo -n true >/dev/null 2>&1 || exit 0
    done
  ) &
  SUDO_KEEPALIVE_PID=$!
  trap setup_cleanup EXIT
}

retry_command() {
  local attempts="$1" delay_seconds="$2" attempt=1
  shift 2
  delay_seconds="${VEDUP_RETRY_DELAY:-$delay_seconds}"
  while ! "$@"; do
    if [ "$attempt" -ge "$attempts" ]; then return 1; fi
    warn "Command failed (attempt $attempt/$attempts); retrying in ${delay_seconds}s: $*"
    sleep "$delay_seconds"
    attempt=$((attempt + 1))
  done
}

# Run independent, no-argument shell functions in bounded batches. This avoids
# wait -n so the implementation also works with the Bash 3.2 shipped by macOS.
run_parallel_tasks() {
  local max_jobs="$1" entry label task start=0 batch_count index pid failed task_status
  local -a entries=() pids=() labels=()
  shift
  entries=("$@")

  if [ "${DRY_RUN:-0}" = 1 ] || [ "$max_jobs" -le 1 ]; then
    for entry in "${entries[@]}"; do
      label="${entry%%|*}"
      task="${entry#*|}"
      log "$label"
      "$task"
    done
    return 0
  fi

  while [ "$start" -lt "${#entries[@]}" ]; do
    pids=()
    labels=()
    batch_count=0
    while [ "$batch_count" -lt "$max_jobs" ] && [ "$start" -lt "${#entries[@]}" ]; do
      entry="${entries[$start]}"
      label="${entry%%|*}"
      task="${entry#*|}"
      (
        trap - ERR EXIT INT TERM
        set -Eeuo pipefail
        log "$label started"
        if "$task"; then
          log "$label complete"
        else
          task_status="$?"
          exit "$task_status"
        fi
      ) &
      pids+=("$!")
      labels+=("$label")
      start=$((start + 1))
      batch_count=$((batch_count + 1))
    done

    failed=0
    index=0
    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then
        warn "${labels[$index]} failed"
        failed=1
      fi
      index=$((index + 1))
    done
    [ "$failed" -eq 0 ] || return 1
  done
}

progress_init() {
  local terminal_columns
  PROGRESS_CURRENT=0
  PROGRESS_COMPACT=0
  PROGRESS_DASHBOARD_DRAWN=0
  PROGRESS_DASHBOARD_ROWS=9
  PROGRESS_ACTIVITY_PID=""
  PROGRESS_FD=1
  PROGRESS_COLUMNS=80
  terminal_columns="$(tput cols 2>/dev/null || true)"
  case "$terminal_columns" in ''|*[!0-9]*) ;; *) PROGRESS_COLUMNS="$terminal_columns" ;; esac
  PROGRESS_STAGE_NAME="Starting setup"
  PROGRESS_STAGE_STARTED="$(date +%s)"
  SETUP_LOG_FILE="${VEDUP_LOG_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/vedup/logs/$(date -u +%Y%m%dT%H%M%SZ)-$$.log}"
  export SETUP_LOG_FILE
  if [ "${DRY_RUN:-0}" != 1 ]; then
    mkdir -p "$(dirname "$SETUP_LOG_FILE")"
    exec 3>&1
    if { [ -t 1 ] || [ "${VEDUP_TEST_COMPACT:-0}" = 1 ]; } && \
      [ "${VERBOSE:-0}" != 1 ] && [ "${TERM:-}" != dumb ]; then
      PROGRESS_COMPACT=1
      PROGRESS_FD=3
      exec >>"$SETUP_LOG_FILE" 2>&1
    else
      exec > >(tee -a "$SETUP_LOG_FILE") 2>&1
    fi
  fi
}

progress_header() {
  printf '%bVedup%b\n' "$SETUP_BOLD" "$SETUP_RESET" >&"$PROGRESS_FD"
  printf 'Machine: %s\nProfile: %s\n' "$1" "$2" >&"$PROGRESS_FD"
  if [ "$PROGRESS_COMPACT" = 1 ]; then
    printf '%bConcise view:%b full output is being saved to %s\n' \
      "$SETUP_DIM" "$SETUP_RESET" "$SETUP_LOG_FILE" >&3
  fi
}

progress_stop_activity() {
  [ -n "${PROGRESS_ACTIVITY_PID:-}" ] || return 0
  kill "$PROGRESS_ACTIVITY_PID" 2>/dev/null || true
  wait "$PROGRESS_ACTIVITY_PID" 2>/dev/null || true
  PROGRESS_ACTIVITY_PID=""
}

progress_start_activity() {
  [ "$PROGRESS_COMPACT" = 1 ] || return 0
  (
    local elapsed frame=0 line limit index
    local frames=('◐' '◓' '◑' '◒')
    trap - ERR
    set +e
    while :; do
      elapsed=$(($(date +%s) - PROGRESS_STAGE_STARTED))
      printf '\0337\033[6A' >&3
      printf '\r\033[2K  %b%s Working · %ss%b\n' "$SETUP_CYAN" "${frames[$frame]}" "$elapsed" "$SETUP_RESET" >&3
      index=0
      limit=$((PROGRESS_COLUMNS - 6))
      [ "$limit" -ge 12 ] || limit=12
      while IFS= read -r line && [ "$index" -lt 5 ]; do
        if [ "${#line}" -gt "$limit" ]; then line="${line:0:$((limit - 3))}..."; fi
        printf '\r\033[2K  %b│%b %s\n' "$SETUP_DIM" "$SETUP_RESET" "$line" >&3
        index=$((index + 1))
      done < <(tail -n 5 "$SETUP_LOG_FILE" 2>/dev/null | awk '{ gsub(sprintf("%c", 27) "\\[[0-9;?]*[ -/]*[@-~]", ""); gsub(/\r/, ""); print }')
      while [ "$index" -lt 5 ]; do
        printf '\r\033[2K  %b│%b\n' "$SETUP_DIM" "$SETUP_RESET" >&3
        index=$((index + 1))
      done
      printf '\0338' >&3
      frame=$(((frame + 1) % ${#frames[@]}))
      sleep "${VEDUP_ACTIVITY_INTERVAL:-0.5}"
    done
  ) &
  PROGRESS_ACTIVITY_PID=$!
}

progress_begin() {
  local stage_name="$1" description="${2:-}" limit
  progress_stop_activity
  PROGRESS_CURRENT=$((PROGRESS_CURRENT + 1))
  PROGRESS_STAGE_NAME="$stage_name"
  if type state_journal >/dev/null 2>&1; then state_journal "$stage_name" running "$description"; fi
  PROGRESS_STAGE_STARTED="$(date +%s)"
  if [ "$PROGRESS_COMPACT" = 1 ]; then
    limit=$((PROGRESS_COLUMNS - 13))
    [ "$limit" -ge 16 ] || limit=16
    if [ "${#stage_name}" -gt "$limit" ]; then stage_name="${stage_name:0:$((limit - 3))}..."; fi
    limit=$((PROGRESS_COLUMNS - 4))
    [ "$limit" -ge 16 ] || limit=16
    if [ "${#description}" -gt "$limit" ]; then description="${description:0:$((limit - 3))}..."; fi
  fi
  PROGRESS_DISPLAY_STAGE="$stage_name"
  if [ "$PROGRESS_COMPACT" = 1 ] && [ "$PROGRESS_DASHBOARD_DRAWN" = 1 ]; then
    printf '\033[%sA' "$PROGRESS_DASHBOARD_ROWS" >&3
  elif [ "$PROGRESS_COMPACT" != 1 ]; then
    printf '\n' >&"$PROGRESS_FD"
  fi
  [ "$PROGRESS_COMPACT" != 1 ] || printf '\r\033[2K' >&3
  progress_bar
  [ "$PROGRESS_COMPACT" != 1 ] || printf '\r\033[2K' >&3
  printf '%b◆%b [%s/%s] %b%s%b\n' "$SETUP_CYAN" "$SETUP_RESET" "$PROGRESS_CURRENT" "$PROGRESS_TOTAL" \
    "$SETUP_BOLD" "$stage_name" "$SETUP_RESET" >&"$PROGRESS_FD"
  [ "$PROGRESS_COMPACT" != 1 ] || printf '\r\033[2K' >&3
  if [ -n "$description" ]; then printf '  %b%s%b\n' "$SETUP_DIM" "$description" "$SETUP_RESET" >&"$PROGRESS_FD"
  else printf '\n' >&"$PROGRESS_FD"; fi
  if [ "$PROGRESS_COMPACT" = 1 ]; then
    printf '  %b◐ Working · 0s%b\n' "$SETUP_CYAN" "$SETUP_RESET" >&3
    printf '  %b│%b\n  %b│%b\n  %b│%b\n  %b│%b\n  %b│%b\n' \
      "$SETUP_DIM" "$SETUP_RESET" "$SETUP_DIM" "$SETUP_RESET" \
      "$SETUP_DIM" "$SETUP_RESET" "$SETUP_DIM" "$SETUP_RESET" \
      "$SETUP_DIM" "$SETUP_RESET" >&3
  fi
  PROGRESS_DASHBOARD_DRAWN=1
  progress_start_activity
}

progress_bar() {
  local width=24 filled empty index bar=""
  if [ "$PROGRESS_COMPACT" = 1 ] && [ "$PROGRESS_COLUMNS" -lt 34 ]; then
    width=$((PROGRESS_COLUMNS - 8))
    [ "$width" -ge 10 ] || width=10
  fi
  filled=$((PROGRESS_CURRENT * width / PROGRESS_TOTAL))
  empty=$((width - filled))
  index=0
  while [ "$index" -lt "$filled" ]; do bar="${bar}█"; index=$((index + 1)); done
  index=0
  while [ "$index" -lt "$empty" ]; do bar="${bar}░"; index=$((index + 1)); done
  printf '%b%s%b  %s%%\n' "$SETUP_PURPLE" "$bar" "$SETUP_RESET" "$((PROGRESS_CURRENT * 100 / PROGRESS_TOTAL))" \
    >&"$PROGRESS_FD"
}

progress_done() {
  local elapsed
  progress_stop_activity
  if type state_journal >/dev/null 2>&1; then state_journal "$PROGRESS_STAGE_NAME" complete "Stage completed"; fi
  elapsed=$(($(date +%s) - PROGRESS_STAGE_STARTED))
  if [ "$PROGRESS_COMPACT" = 1 ]; then
    printf '\033[%sA' "$PROGRESS_DASHBOARD_ROWS" >&3
    printf '\r\033[2K' >&3
    progress_bar
    printf '\r\033[2K%b◆%b [%s/%s] %b%s%b\n' "$SETUP_CYAN" "$SETUP_RESET" \
      "$PROGRESS_CURRENT" "$PROGRESS_TOTAL" "$SETUP_BOLD" "$PROGRESS_DISPLAY_STAGE" "$SETUP_RESET" >&3
    printf '\r\033[2K' >&3
  fi
  if [ "${DRY_RUN:-0}" = 1 ]; then
    printf '  %b✓%b Previewed %b(%ss)%b\n' "$SETUP_GREEN" "$SETUP_RESET" "$SETUP_DIM" "$elapsed" "$SETUP_RESET" \
      >&"$PROGRESS_FD"
  else
    printf '  %b✓%b Complete %b(%ss)%b\n' "$SETUP_GREEN" "$SETUP_RESET" "$SETUP_DIM" "$elapsed" "$SETUP_RESET" \
      >&"$PROGRESS_FD"
  fi
  if [ "$PROGRESS_COMPACT" = 1 ]; then
    printf '\r\033[2K\n\r\033[2K\n\r\033[2K\n\r\033[2K\n\r\033[2K\n\r\033[2K\n' >&3
  fi
}

progress_restore_terminal() {
  [ "${PROGRESS_COMPACT:-0}" = 1 ] || return 0
  progress_stop_activity
  if [ "${PROGRESS_DASHBOARD_DRAWN:-0}" = 1 ]; then
    printf '\033[%sA' "$PROGRESS_DASHBOARD_ROWS" >&3
    local row=0
    while [ "$row" -lt "$PROGRESS_DASHBOARD_ROWS" ]; do
      printf '\r\033[2K\n' >&3
      row=$((row + 1))
    done
  fi
  exec 1>&3 2>&3
  PROGRESS_COMPACT=0
  PROGRESS_FD=1
  PROGRESS_DASHBOARD_DRAWN=0
}

progress_failed() {
  local code="$1" line="$2"
  local was_compact="${PROGRESS_COMPACT:-0}"
  trap - ERR
  [ "$was_compact" != 1 ] || progress_restore_terminal
  printf '\n%b✗ Vedup stopped while %s.%b\n' "$SETUP_RED" "$PROGRESS_STAGE_NAME" "$SETUP_RESET" >&2
  if [ -n "${SETUP_LOG_FILE:-}" ] && [ "${DRY_RUN:-0}" != 1 ]; then
    if [ "$was_compact" = 1 ]; then
      printf '\nLast activity:\n' >&2
      tail -n 18 "$SETUP_LOG_FILE" | sed 's/^/  │ /' >&2
      printf '\n' >&2
    fi
    printf '  Detailed log: %s\n' "$SETUP_LOG_FILE" >&2
    printf '  Exit %s near internal line %s. Your previous working setup remains active.\n' "$code" "$line" >&2
    printf '  Fix the reported issue, then run vedup sync or the one-line installer again.\n' >&2
  fi
  exit "$code"
}

progress_finish() {
  local state_dir latest_dotfiles latest_macos external_count retained_count
  local warning_count
  progress_restore_terminal
  if [ "${DRY_RUN:-0}" = 1 ]; then
    printf '\n%b╭─ Preview ready ────────────────────────────────────────────╮%b\n' "$SETUP_PURPLE" "$SETUP_RESET"
    printf '  No machine changes were made.\n'
  else
    printf '\n%b╭─ Your machine is ready ────────────────────────────────────╮%b\n' "$SETUP_GREEN" "$SETUP_RESET"
    printf '  %b✓%b Vedup finished successfully.\n' "$SETUP_GREEN" "$SETUP_RESET"
  fi
  if [ "${DRY_RUN:-0}" != 1 ]; then
    printf 'Detailed log: %s\n' "$SETUP_LOG_FILE"
    warning_count="$(grep -c '\[setup\] WARN:' "$SETUP_LOG_FILE" 2>/dev/null || true)"
    if [ "${warning_count:-0}" -gt 0 ]; then
      printf '%bWarnings:%b %s (see the detailed log)\n' "$SETUP_YELLOW" "$SETUP_RESET" "$warning_count"
    fi
    if [ -r "${PLAN_FILE:-}" ]; then
      external_count="$(awk -F '\t' '$1 == "keep" && $4 == "external" { count++ } END { print count+0 }' "$PLAN_FILE")"
      retained_count="$(awk -F '\t' '$2 ~ /^retained:/ { count++ } END { print count+0 }' "$PLAN_FILE")"
      printf 'Changes: %s installed, %s updated, %s configured; %s already ready.\n' \
        "${PLAN_INSTALL_COUNT:-0}" "${PLAN_UPDATE_COUNT:-0}" "${PLAN_CONFIGURE_COUNT:-0}" "${PLAN_KEEP_COUNT:-0}"
      [ "$external_count" -eq 0 ] || printf 'Retained external software: %s resource(s).\n' "$external_count"
      [ "$retained_count" -eq 0 ] || printf 'Retained but unselected: %s resource(s); see the plan for manual removal guidance.\n' "$retained_count"
    fi
    state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/vedup"
    latest_dotfiles="$(awk 'NF { value=$0 } END { print value }' "$state_dir/backups.list" 2>/dev/null || true)"
    latest_macos="$(awk 'NF { value=$0 } END { print value }' "$state_dir/macos-preferences.list" 2>/dev/null || true)"
    if [ -n "$latest_dotfiles" ] || [ -n "$latest_macos" ]; then
      printf 'Recovery snapshots:\n'
      [ -z "$latest_dotfiles" ] || printf '  Dotfiles:          %s\n' "$latest_dotfiles"
      [ -z "$latest_macos" ] || printf '  macOS preferences: %s\n' "$latest_macos"
    fi
    if [ "${WITH_DOCKER:-0}" = 1 ] && [ "${OS:-}" = linux ]; then
      printf 'Action required: log out and back in once before using Docker without sudo.\n'
    fi
    if [ "${OS:-}" = macos ] && [ "${PROFILE:-}" = workstation ]; then
      printf 'If requested: sign into the App Store and approve app permissions on first launch.\n'
    fi
    if [ "${KEYBOARD_SHORTCUTS:-0}" = 1 ] || [ "${EXPERIMENTAL_MACOS_DEFAULTS:-0}" = 1 ]; then
      printf 'Some macOS changes may require logging out or restarting the affected application.\n'
    fi
  fi
  printf '%bNext:%b open a new terminal to use the configured shell and PATH.\n' "$SETUP_CYAN" "$SETUP_RESET"
  printf 'Run %bvedup%b any time to sync, update Vedup, customize, save, or diagnose.\n' "$SETUP_BOLD" "$SETUP_RESET"
  printf '%b╰────────────────────────────────────────────────────────────╯%b\n' "$([ "${DRY_RUN:-0}" = 1 ] && printf '%s' "$SETUP_PURPLE" || printf '%s' "$SETUP_GREEN")" "$SETUP_RESET"
}

quote_command() {
  printf ' %q' "$@"
  printf '\n'
}

run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '[dry-run]'
    quote_command "$@"
    return 0
  fi
  "$@"
}

sudo_run() {
  if [ "$(id -u)" -eq 0 ]; then
    run "$@"
  elif has sudo; then
    run sudo -n "$@"
  else
    die "Administrator access is required for: $*"
  fi
}

sha256_file() {
  if has sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  elif has shasum; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "A SHA-256 tool (sha256sum or shasum) is required."
  fi
}

download_verified() {
  local url="$1" expected="$2" output="$3" force="${4:-0}" actual
  if [ "$force" = force ]; then mkdir -p "$(dirname "$output")"
  else run mkdir -p "$(dirname "$output")"; fi
  if [ "${DRY_RUN:-0}" = "1" ] && [ "$force" != force ]; then
    printf '[dry-run] download %s -> %s (sha256 %s)\n' "$url" "$output" "$expected"
    return 0
  fi
  curl -fsSL --retry 3 --proto '=https' --tlsv1.2 "$url" -o "$output"
  actual="$(sha256_file "$output")"
  [ "$actual" = "$expected" ] || die "Checksum mismatch for $url"
}

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}
