#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2119,SC2120

# Managed configuration is intentionally writable. Home-directory links point
# at this stable worktree rather than an immutable release, while base retains
# the last pristine template for conflict-safe three-way synchronization.
VEDUP_CONFIG_ROOT="${VEDUP_CONFIG_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/vedup/config}"
VEDUP_CONFIG_WORKTREE="$VEDUP_CONFIG_ROOT/worktree"
VEDUP_CONFIG_BASE="$VEDUP_CONFIG_ROOT/base"
VEDUP_CONFIG_CONFLICTS="${VEDUP_CONFIG_CONFLICTS:-${VEDUP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vedup}/config-conflicts.tsv}"
CONFIG_NEEDS_UPDATE=0
CONFIG_CONFLICT_COUNT=0
CONFIG_ROLLBACK_ARMED=0
CONFIG_STAGE_ROOT=""

config_entry_exists() { [ -e "$1" ] || [ -L "$1" ]; }

config_entry_same() {
  local left="$1" right="$2"
  config_entry_exists "$left" && config_entry_exists "$right" || return 1
  if [ -L "$left" ] || [ -L "$right" ]; then
    [ -L "$left" ] && [ -L "$right" ] && [ "$(readlink "$left")" = "$(readlink "$right")" ]
  elif [ -f "$left" ] && [ -f "$right" ]; then
    cmp -s "$left" "$right"
  else
    return 1
  fi
}

config_copy_entry() {
  local source="$1" destination="$2"
  mkdir -p "$(dirname "$destination")"
  rm -f "$destination"
  cp -P "$source" "$destination"
}

config_path_list() {
  local root package source
  for root in "$REPO_ROOT/dotfiles" "$VEDUP_CONFIG_BASE" "$VEDUP_CONFIG_WORKTREE"; do
    [ -d "$root" ] || continue
    for package in "${STOW_PACKAGES[@]}"; do
      [ -d "$root/$package" ] || continue
      while IFS= read -r -d '' source; do
        printf '%s\n' "${source#"$root"/}"
      done < <(find "$root/$package" \( -type f -o -type l \) \
        ! -name .gitignore ! -name .gitmodules ! -name .cvsignore ! -name .DS_Store -print0)
    done
  done | LC_ALL=C sort -u
}

config_scan() {
  local path incoming base local_entry incoming_exists base_exists local_exists
  CONFIG_NEEDS_UPDATE=0 CONFIG_CONFLICT_COUNT=0
  if { [ ! -d "$VEDUP_CONFIG_BASE" ] && [ ! -d "$VEDUP_CONFIG_WORKTREE" ]; }; then
    CONFIG_NEEDS_UPDATE=1
    return 0
  fi
  if [ ! -d "$VEDUP_CONFIG_BASE" ] || [ ! -d "$VEDUP_CONFIG_WORKTREE" ]; then
    CONFIG_CONFLICT_COUNT=1
    return 0
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    incoming="$REPO_ROOT/dotfiles/$path" base="$VEDUP_CONFIG_BASE/$path" local_entry="$VEDUP_CONFIG_WORKTREE/$path"
    incoming_exists=0 base_exists=0 local_exists=0
    config_entry_exists "$incoming" && incoming_exists=1
    config_entry_exists "$base" && base_exists=1
    config_entry_exists "$local_entry" && local_exists=1
    if [ "$incoming_exists" = 1 ] && [ "$base_exists" = 1 ]; then
      config_entry_same "$incoming" "$base" && continue
      if [ "$local_exists" = 1 ] && { config_entry_same "$local_entry" "$base" || config_entry_same "$local_entry" "$incoming"; }; then
        CONFIG_NEEDS_UPDATE=1
      else
        CONFIG_CONFLICT_COUNT=$((CONFIG_CONFLICT_COUNT + 1))
      fi
    elif [ "$incoming_exists" = 1 ] && [ "$base_exists" = 0 ]; then
      if [ "$local_exists" = 0 ] || config_entry_same "$local_entry" "$incoming"; then
        CONFIG_NEEDS_UPDATE=1
      else
        CONFIG_CONFLICT_COUNT=$((CONFIG_CONFLICT_COUNT + 1))
      fi
    elif [ "$incoming_exists" = 0 ] && [ "$base_exists" = 1 ]; then
      if [ "$local_exists" = 0 ] || config_entry_same "$local_entry" "$base"; then
        CONFIG_NEEDS_UPDATE=1
      else
        CONFIG_CONFLICT_COUNT=$((CONFIG_CONFLICT_COUNT + 1))
      fi
    fi
  done < <(config_path_list)
}

config_record_conflict() {
  local path="$1" reason="$2"
  CONFIG_CONFLICT_COUNT=$((CONFIG_CONFLICT_COUNT + 1))
  printf '%s\t%s\n' "$path" "$reason" >> "$CONFIG_STAGE_ROOT/conflicts.tsv"
}

config_seed_new_workspace() {
  local package
  mkdir -p "$CONFIG_STAGE_ROOT/base" "$CONFIG_STAGE_ROOT/worktree"
  for package in "${STOW_PACKAGES[@]}"; do
    [ -d "$REPO_ROOT/dotfiles/$package" ] || continue
    cp -R "$REPO_ROOT/dotfiles/$package" "$CONFIG_STAGE_ROOT/base/$package"
    cp -R "$REPO_ROOT/dotfiles/$package" "$CONFIG_STAGE_ROOT/worktree/$package"
  done
}

config_merge_workspace() {
  local path incoming base local_entry staged incoming_exists base_exists local_exists package
  mkdir -p "$CONFIG_STAGE_ROOT/base" "$CONFIG_STAGE_ROOT/worktree"
  cp -R "$VEDUP_CONFIG_WORKTREE/." "$CONFIG_STAGE_ROOT/worktree/"
  : > "$CONFIG_STAGE_ROOT/conflicts.tsv"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    incoming="$REPO_ROOT/dotfiles/$path" base="$VEDUP_CONFIG_BASE/$path" local_entry="$VEDUP_CONFIG_WORKTREE/$path"
    staged="$CONFIG_STAGE_ROOT/worktree/$path"
    incoming_exists=0 base_exists=0 local_exists=0
    config_entry_exists "$incoming" && incoming_exists=1
    config_entry_exists "$base" && base_exists=1
    config_entry_exists "$local_entry" && local_exists=1
    if [ "$incoming_exists" = 1 ] && [ "$base_exists" = 1 ]; then
      if config_entry_same "$incoming" "$base"; then :
      elif [ "$local_exists" = 1 ] && config_entry_same "$local_entry" "$base"; then config_copy_entry "$incoming" "$staged"
      elif [ "$local_exists" = 1 ] && config_entry_same "$local_entry" "$incoming"; then :
      else config_record_conflict "$path" modified-both; fi
    elif [ "$incoming_exists" = 1 ] && [ "$base_exists" = 0 ]; then
      if [ "$local_exists" = 0 ]; then config_copy_entry "$incoming" "$staged"
      elif config_entry_same "$local_entry" "$incoming"; then :
      else config_record_conflict "$path" added-both; fi
    elif [ "$incoming_exists" = 0 ] && [ "$base_exists" = 1 ]; then
      if [ "$local_exists" = 0 ]; then :
      elif config_entry_same "$local_entry" "$base"; then rm -f "$staged"
      else config_record_conflict "$path" removed-upstream-modified-locally; fi
    fi
  done < <(config_path_list)
  [ "$CONFIG_CONFLICT_COUNT" -eq 0 ] || return 1
  for package in "${STOW_PACKAGES[@]}"; do
    [ -d "$REPO_ROOT/dotfiles/$package" ] || continue
    cp -R "$REPO_ROOT/dotfiles/$package" "$CONFIG_STAGE_ROOT/base/$package"
  done
}

config_prepare_workspace() {
  CONFIG_STAGE_ROOT="$VEDUP_TRANSACTION_DIR/config-stage"
  CONFIG_CONFLICT_COUNT=0
  rm -rf "$CONFIG_STAGE_ROOT"
  mkdir -p "$CONFIG_STAGE_ROOT"
  if [ -d "$VEDUP_CONFIG_BASE" ] && [ -d "$VEDUP_CONFIG_WORKTREE" ]; then
    config_merge_workspace || return 1
  else
    config_seed_new_workspace
  fi
}

config_activate_workspace() {
  local previous="$VEDUP_TRANSACTION_DIR/config-previous" markers="$VEDUP_TRANSACTION_DIR/config-activation.tsv"
  mkdir -p "$VEDUP_CONFIG_ROOT" "$previous"
  : > "$markers"
  CONFIG_ROLLBACK_ARMED=1
  if [ -d "$VEDUP_CONFIG_BASE" ]; then
    if ! mv "$VEDUP_CONFIG_BASE" "$previous/base"; then return 1; fi
    printf 'saved\tbase\n' >> "$markers"
  else
    printf 'absent\tbase\n' >> "$markers"
  fi
  if [ -d "$VEDUP_CONFIG_WORKTREE" ]; then
    if ! mv "$VEDUP_CONFIG_WORKTREE" "$previous/worktree"; then
      config_rollback_workspace
      return 1
    fi
    printf 'saved\tworktree\n' >> "$markers"
  else
    printf 'absent\tworktree\n' >> "$markers"
  fi
  if ! mv "$CONFIG_STAGE_ROOT/base" "$VEDUP_CONFIG_BASE"; then
    config_rollback_workspace
    return 1
  fi
  printf 'installed\tbase\n' >> "$markers"
  if ! mv "$CONFIG_STAGE_ROOT/worktree" "$VEDUP_CONFIG_WORKTREE"; then
    config_rollback_workspace
    return 1
  fi
  printf 'installed\tworktree\n' >> "$markers"
  if [ -s "$CONFIG_STAGE_ROOT/conflicts.tsv" ]; then
    cp "$CONFIG_STAGE_ROOT/conflicts.tsv" "$VEDUP_CONFIG_CONFLICTS"
  else
    rm -f "$VEDUP_CONFIG_CONFLICTS"
  fi
  type state_journal >/dev/null 2>&1 && state_journal configuration activated "Writable managed configuration workspace activated"
  return 0
}

config_rollback_workspace() {
  local transaction="${1:-${VEDUP_TRANSACTION_DIR:-}}" previous markers
  [ -n "$transaction" ] || return 0
  previous="$transaction/config-previous"
  markers="$transaction/config-activation.tsv"
  [ "$CONFIG_ROLLBACK_ARMED" = 1 ] || [ -s "$markers" ] || return 0
  grep -Eq '^(rolled-back|committed)$' "$markers" 2>/dev/null && return 0
  if grep -Fqx $'installed\tbase' "$markers" 2>/dev/null; then rm -rf "$VEDUP_CONFIG_BASE"; fi
  if grep -Fqx $'installed\tworktree' "$markers" 2>/dev/null; then rm -rf "$VEDUP_CONFIG_WORKTREE"; fi
  if grep -Fqx $'saved\tbase' "$markers" 2>/dev/null && [ -d "$previous/base" ]; then
    [ ! -e "$VEDUP_CONFIG_BASE" ] || return 1
    mv "$previous/base" "$VEDUP_CONFIG_BASE"
  fi
  if grep -Fqx $'saved\tworktree' "$markers" 2>/dev/null && [ -d "$previous/worktree" ]; then
    [ ! -e "$VEDUP_CONFIG_WORKTREE" ] || return 1
    mv "$previous/worktree" "$VEDUP_CONFIG_WORKTREE"
  fi
  printf 'rolled-back\n' >> "$markers"
  CONFIG_ROLLBACK_ARMED=0
  type state_journal >/dev/null 2>&1 && state_journal configuration rolled-back "Previous managed configuration workspace restored"
  return 0
}

config_commit_workspace() {
  [ -n "${VEDUP_TRANSACTION_DIR:-}" ] && [ -f "$VEDUP_TRANSACTION_DIR/config-activation.tsv" ] && \
    printf 'committed\n' >> "$VEDUP_TRANSACTION_DIR/config-activation.tsv"
  CONFIG_ROLLBACK_ARMED=0
  type state_journal >/dev/null 2>&1 && state_journal configuration committed "Writable configuration verified"
  return 0
}

config_dotfiles_root() {
  if [ -d "$VEDUP_CONFIG_WORKTREE" ]; then printf '%s' "$VEDUP_CONFIG_WORKTREE"
  else printf '%s' "$REPO_ROOT/dotfiles"; fi
}

config_capture_changes() {
  local path base local_entry base_exists local_exists
  [ -d "$VEDUP_CONFIG_BASE" ] && [ -d "$VEDUP_CONFIG_WORKTREE" ] || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    base="$VEDUP_CONFIG_BASE/$path" local_entry="$VEDUP_CONFIG_WORKTREE/$path"
    base_exists=0 local_exists=0
    config_entry_exists "$base" && base_exists=1
    config_entry_exists "$local_entry" && local_exists=1
    if [ "$base_exists" = 1 ] && [ "$local_exists" = 1 ]; then
      config_entry_same "$base" "$local_entry" || printf 'modified\t%s\n' "$path"
    elif [ "$base_exists" = 0 ] && [ "$local_exists" = 1 ]; then
      printf 'added\t%s\n' "$path"
    elif [ "$base_exists" = 1 ] && [ "$local_exists" = 0 ]; then
      printf 'deleted\t%s\n' "$path"
    fi
  done < <(config_path_list)
}

config_path_is_safe_to_capture() {
  local relative="$1" file="${2:-}" first_component
  case "$relative" in ''|/*|*..*|*$'\t'*|*$'\n'*|*$'\r'*) return 1 ;; esac
  first_component="${relative%%/*}"
  case "$first_component" in zsh|nvim|starship|tmux|scripts|aerospace|ghostty|cursor) ;; *) return 1 ;; esac
  case "$relative" in
    *.local|*.local.*|*/.env|*/.env.*|*.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|*/.zsh_history|*/.bash_history|*/.python_history|*/.node_repl_history|*/history|*.history|*credential*|*Credential*|*secret*|*Secret*|*token*|*Token*) return 1 ;;
  esac
  [ -z "$file" ] && return 0
  [ ! -L "$file" ] || return 1
  [ -f "$file" ] || return 1
  if grep -Eiq 'BEGIN ([A-Z ]+ )?PRIVATE KEY|(AKIA|ASIA)[0-9A-Z]{16}|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-(proj|svcacct)-[A-Za-z0-9_-]{12,}|(^|[^A-Za-z])(password|passwd|access[_-]?token|secret[_-]?key|api[_-]?key|private[_-]?key)[[:space:]]*[:=]|authorization[[:space:]]*:[[:space:]]*bearer|[A-Za-z][A-Za-z0-9+.-]*://[^/@[:space:]]+:[^/@[:space:]]+@' "$file"; then
    return 1
  fi
}
