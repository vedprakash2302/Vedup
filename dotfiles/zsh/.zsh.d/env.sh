# History setup
export HISTFILE=$HOME/.zhistory
export SAVEHIST=100000
export HISTSIZE=100000

# Pinned Mise shims take precedence over unrelated user-local binaries. The CLI
# release and last successfully applied machine release intentionally differ:
# `vedup update` must not change runtimes before `vedup sync` succeeds.
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
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

# Fzf exports
export FZF_DEFAULT_OPTS="--preview 'bat --color=always {}'"
export FZF_DEFAULT_COMMAND="fd --type f"

# Starship config
export STARSHIP_CONFIG="$HOME/.config/starship/gruvbox.toml"
