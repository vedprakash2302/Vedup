# Add pinned community completion functions before compinit runs.
export VEDUP_ZSH_PLUGIN_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/vedup/zsh/plugins"
if [[ -d "$VEDUP_ZSH_PLUGIN_ROOT/zsh-completions/src" ]]; then
  typeset -gaU fpath
  fpath=("$VEDUP_ZSH_PLUGIN_ROOT/zsh-completions/src" $fpath)
fi

vedup_init_completions() {
  emulate -L zsh
  setopt local_options no_aliases

  local cache_dir dump_file completion_dir cache_fresh=0
  local -a stat_info
  cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/vedup/zsh"
  dump_file="$cache_dir/zcompdump-${ZSH_VERSION}"
  completion_dir="$VEDUP_ZSH_PLUGIN_ROOT/zsh-completions/src"
  [[ -d "$cache_dir" ]] || command mkdir -p -- "$cache_dir" 2>/dev/null || return 1

  autoload -Uz compinit
  zmodload zsh/datetime 2>/dev/null
  zmodload zsh/stat 2>/dev/null
  if [[ -s "$dump_file" && "${VEDUP_ZSH_REFRESH_CACHE:-0}" != 1 ]] && \
    zstat -A stat_info +mtime -- "$dump_file" 2>/dev/null && \
    (( EPOCHSECONDS - stat_info[1] >= 0 && EPOCHSECONDS - stat_info[1] < 86400 )); then
    if [[ ! -d "$completion_dir" || ! "$completion_dir" -nt "$dump_file" ]]; then
      cache_fresh=1
    fi
  fi

  if (( cache_fresh )); then
    compinit -C -d "$dump_file"
  else
    # A full daily check prevents compromised completion directories from being
    # added while keeping ordinary shell startup fast and non-interactive.
    compinit -i -d "$dump_file"
  fi
}
