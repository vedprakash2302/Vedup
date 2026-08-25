# Cache generated shell integrations atomically. Warm shells only source files;
# a cache is rebuilt when its tool, Mise configuration, or this helper changes.
vedup_prepare_init_cache() {
  emulate -L zsh
  setopt local_options no_aliases

  local cache_name="$1" generator="$2" tool_path cache_dir cache_file cache_tmp dependency
  shift 2
  typeset -g VEDUP_INIT_CACHE_FILE=''
  tool_path="${commands[$generator]:-}"
  [[ -n "$tool_path" ]] || return 0

  cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/vedup/zsh/init"
  [[ -d "$cache_dir" ]] || command mkdir -p -- "$cache_dir" 2>/dev/null || return 0
  cache_file="$cache_dir/${cache_name}.zsh"
  cache_tmp="$cache_file.tmp.$$.$RANDOM"

  local refresh=0
  [[ -s "$cache_file" ]] || refresh=1
  [[ "$tool_path" -nt "$cache_file" ]] && refresh=1
  [[ "${VEDUP_ZSH_REFRESH_CACHE:-0}" == 1 ]] && refresh=1
  for dependency in \
    "$HOME/.zsh.d/init-cache.sh" \
    "${VEDUP_ROOT:-}/mise.toml" \
    "${VEDUP_ROOT:-}/mise.lock"; do
    [[ -n "$dependency" && -e "$dependency" && "$dependency" -nt "$cache_file" ]] && refresh=1
  done

  if (( refresh )); then
    umask 077
    if command "$generator" "$@" >| "$cache_tmp" 2>/dev/null && \
      command zsh -n "$cache_tmp" >/dev/null 2>&1; then
      command mv -f -- "$cache_tmp" "$cache_file" || return 0
    else
      command rm -f -- "$cache_tmp" 2>/dev/null
    fi
  fi

  [[ -r "$cache_file" ]] && typeset -g VEDUP_INIT_CACHE_FILE="$cache_file"
}
