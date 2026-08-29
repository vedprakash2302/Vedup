# History setup
export HISTFILE=$HOME/.zhistory
export SAVEHIST=100000
export HISTSIZE=100000

# Fzf exports
export FZF_DEFAULT_OPTS="--preview 'bat --color=always {}'"
export FZF_DEFAULT_COMMAND="fd --type f"

# Starship config
export STARSHIP_CONFIG="$HOME/.config/starship/gruvbox.toml"
