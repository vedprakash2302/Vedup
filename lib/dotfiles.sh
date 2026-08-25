#!/usr/bin/env bash

DOTFILES_ROLLBACK_ARMED=0
DOTFILES_ROLLBACK_MANIFEST=""

dotfiles_record() {
  local kind="$1" target="$2" saved="$3"
  [ "${DRY_RUN:-0}" != 1 ] || return 0
  printf '%s\t%s\t%s\n' "$kind" "$target" "$saved" >> "$DOTFILES_ROLLBACK_MANIFEST"
  if type state_journal >/dev/null 2>&1; then
    state_journal dotfiles backup "$kind $target"
  fi
}

dotfiles_register_backup_dir() {
  local ledger="${VEDUP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vedup}/backups.list"
  [ "${DRY_RUN:-0}" != 1 ] || return 0
  mkdir -p "$(dirname "$ledger")"
  grep -Fqx "$BACKUP_DIR" "$ledger" 2>/dev/null || printf '%s\n' "$BACKUP_DIR" >> "$ledger"
}

backup_target() {
  local target="$1" relative="$2" destination
  destination="$BACKUP_DIR/$relative"
  log "Backing up $target"
  run mkdir -p "$(dirname "$destination")"
  if [ "${DRY_RUN:-0}" != 1 ]; then
    mv "$target" "$destination"
    dotfiles_record backup "$target" "$destination"
    dotfiles_register_backup_dir
  else
    run mv "$target" "$destination"
  fi
  BACKUP_OCCURRED=1
}

is_managed_link() {
  local target="$1" source="$2"
  [ -L "$target" ] || return 1
  [ "$target" -ef "$source" ]
}

is_previous_vedup_link() {
  local target="$1" link
  [ -L "$target" ] || return 1
  link="$(readlink "$target")"
  case "$link" in
    */vedup/releases/*/dotfiles/*|*/vedup/current/dotfiles/*|*/vedup/config/worktree/*) return 0 ;;
    *) return 1 ;;
  esac
}

replace_previous_link() {
  local target="$1" previous
  previous="$(readlink "$target")"
  log "Replacing previous Vedup link $target"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    run unlink "$target"
  else
    dotfiles_record link "$target" "$previous"
    unlink "$target"
  fi
}

prepare_parent_path() {
  local relative="$1" current="$HOME" part prefix=""
  IFS='/' read -r -a parts <<< "$(dirname "$relative")"
  for part in "${parts[@]}"; do
    [ "$part" = "." ] && continue
    prefix="${prefix:+$prefix/}$part"
    current="$HOME/$prefix"
    if [ -L "$current" ]; then
      if is_previous_vedup_link "$current"; then
        replace_previous_link "$current"
      else
        backup_target "$current" "$prefix"
      fi
    elif [ -e "$current" ] && [ ! -d "$current" ]; then
      backup_target "$current" "$prefix"
    fi
    run mkdir -p "$current"
  done
}

prepare_package_conflicts() {
  local package="$1" package_dir source relative target
  package_dir="$DOTFILES_ROOT/$package"
  [ -d "$package_dir" ] || die "Dotfile package does not exist: $package"

  while IFS= read -r -d '' source; do
    relative="${source#"$package_dir"/}"
    target="$HOME/$relative"
    prepare_parent_path "$relative"

    if is_managed_link "$target" "$source"; then
      [ "${DRY_RUN:-0}" = 1 ] || dotfiles_record link "$target" "$(readlink "$target")"
      continue
    elif is_previous_vedup_link "$target"; then
      replace_previous_link "$target"
    elif [ -e "$target" ] || [ -L "$target" ]; then
      backup_target "$target" "$relative"
    fi
  done < <(find "$package_dir" \( -type f -o -type l \) \
    ! -name .gitignore ! -name .gitmodules ! -name .cvsignore ! -name .DS_Store -print0)
}

dotfiles_preflight() {
  local package preflight_dir
  for package in "${STOW_PACKAGES[@]}"; do
    [ -d "$DOTFILES_ROOT/$package" ] || die "Dotfile package does not exist: $package"
  done
  [ "${DRY_RUN:-0}" = 1 ] && return 0
  if [ ! -d "$HOME" ] || [ ! -w "$HOME" ]; then die "The home directory is not writable: $HOME"; fi
  preflight_dir="$(mktemp -d "${TMPDIR:-/tmp}/vedup-stow-preflight.XXXXXX")"
  if ! stow --simulate --no-folding --restow --target="$preflight_dir" \
      --dir="$DOTFILES_ROOT" "${STOW_PACKAGES[@]}" >/dev/null 2>&1; then
    rm -rf "$preflight_dir"
    die "Stow preflight failed before any configuration was moved."
  fi
  rm -rf "$preflight_dir"
}

dotfiles_rollback() {
  local kind target saved index
  local -a entries=()
  [ "${DOTFILES_ROLLBACK_ARMED:-0}" = 1 ] || return 0
  DOTFILES_ROLLBACK_ARMED=0
  warn "Restoring dotfile links and conflicts from the interrupted synchronization."

  for package in "${STOW_PACKAGES[@]}"; do
    stow --no-folding --delete --target="$HOME" --dir="$DOTFILES_ROOT" "$package" >/dev/null 2>&1 || true
  done

  while IFS= read -r entry; do entries+=("$entry"); done < "$DOTFILES_ROLLBACK_MANIFEST"
  for ((index=${#entries[@]} - 1; index >= 0; index--)); do
    IFS=$'\t' read -r kind target saved <<< "${entries[$index]}"
    case "$kind" in
      backup)
        if [ -e "$saved" ] || [ -L "$saved" ]; then
          [ ! -L "$target" ] || rm -f "$target"
          mkdir -p "$(dirname "$target")"
          mv "$saved" "$target"
        fi
        ;;
      link)
        [ ! -L "$target" ] || rm -f "$target"
        if [ ! -e "$target" ]; then
          mkdir -p "$(dirname "$target")"
          ln -s "$saved" "$target"
        fi
        ;;
    esac
  done
  type state_journal >/dev/null 2>&1 && state_journal dotfiles rolled-back "Links and conflicts restored"
}

dotfiles_commit() {
  DOTFILES_ROLLBACK_ARMED=0
  type state_journal >/dev/null 2>&1 && state_journal dotfiles committed "Configuration verified"
}

setup_dotfiles() {
  local package
  export BACKUP_OCCURRED=0
  BACKUP_DIR="${BACKUP_DIR:-${VEDUP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vedup}/backups/$(date -u +%Y%m%dT%H%M%SZ)-$$}"
  export BACKUP_DIR
  DOTFILES_ROLLBACK_MANIFEST="${VEDUP_TRANSACTION_DIR:-$BACKUP_DIR}/dotfiles-rollback.tsv"
  export DOTFILES_ROLLBACK_MANIFEST

  dotfiles_preflight
  if [ "${DRY_RUN:-0}" != 1 ]; then
    mkdir -p "$(dirname "$DOTFILES_ROLLBACK_MANIFEST")"
    : > "$DOTFILES_ROLLBACK_MANIFEST"
    DOTFILES_ROLLBACK_ARMED=1
  fi

  for package in "${STOW_PACKAGES[@]}"; do prepare_package_conflicts "$package"; done

  for package in "${STOW_PACKAGES[@]}"; do
    log "Linking $package dotfiles"
    if ! run stow --no-folding --restow --target="$HOME" --dir="$DOTFILES_ROOT" "$package"; then
      dotfiles_rollback
      return 1
    fi
  done
}
