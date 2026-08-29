# Keep every Zsh process on the same quiet, pinned tool path. This file is read
# by interactive terminals and automation, so it must not print output or load
# prompt, completion, or line-editor integrations.
typeset -U path PATH
typeset -a vedup_platform_path
if [[ "$OSTYPE" == darwin* ]]; then
  [[ -d /opt/homebrew/bin ]] && vedup_platform_path+=(/opt/homebrew/bin /opt/homebrew/sbin)
  [[ -d /usr/local/bin ]] && vedup_platform_path+=(/usr/local/bin)
fi
path=("$HOME/.local/share/mise/shims" "$HOME/.local/bin" $vedup_platform_path $path)
export PATH
unset vedup_platform_path

# The CLI release may be newer than the policy successfully applied by sync.
# Keep runtimes on the applied release until the next successful synchronization.
export VEDUP_CLI_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/vedup/current"
export VEDUP_ROOT="${VEDUP_APPLIED_RELEASE:-${XDG_DATA_HOME:-$HOME/.local/share}/vedup/applied}"
if [[ ! -r "$VEDUP_ROOT/mise.toml" && -r "$VEDUP_CLI_ROOT/mise.toml" ]]; then
  VEDUP_ROOT="$VEDUP_CLI_ROOT"
fi
[[ -r "$VEDUP_ROOT/mise.toml" ]] && export MISE_CONFIG_FILE="$VEDUP_ROOT/mise.toml"

if (( $+commands[nvim] )); then
  export GIT_EDITOR=nvim
  export EDITOR=nvim
else
  export GIT_EDITOR=vim
  export EDITOR=vim
fi
