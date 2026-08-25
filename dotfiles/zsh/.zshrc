# Vedup's shell is assembled from small, independently editable modules. Shell
# startup is deliberately offline: installation and updates happen via `vedup`.
typeset -g VEDUP_ZSH_MODULES="$HOME/.zsh.d"

# Environment and completion paths must exist before command initialization.
[[ -r "$VEDUP_ZSH_MODULES/env.sh" ]] && source "$VEDUP_ZSH_MODULES/env.sh"
[[ -r "$VEDUP_ZSH_MODULES/completions.sh" ]] && source "$VEDUP_ZSH_MODULES/completions.sh"
[[ -r "$VEDUP_ZSH_MODULES/init-cache.sh" ]] && source "$VEDUP_ZSH_MODULES/init-cache.sh"

if [[ -o interactive ]]; then
  (( $+functions[vedup_init_completions] )) && vedup_init_completions

  if (( $+functions[vedup_prepare_init_cache] )); then
    vedup_prepare_init_cache mise mise activate zsh
    [[ -r "$VEDUP_INIT_CACHE_FILE" ]] && source "$VEDUP_INIT_CACHE_FILE"
    vedup_prepare_init_cache zoxide zoxide init zsh
    [[ -r "$VEDUP_INIT_CACHE_FILE" ]] && source "$VEDUP_INIT_CACHE_FILE"
    vedup_prepare_init_cache fzf fzf --zsh
    [[ -r "$VEDUP_INIT_CACHE_FILE" ]] && source "$VEDUP_INIT_CACHE_FILE"
    if (( $+commands[carapace] )); then
      export CARAPACE_BRIDGES='zsh'
      vedup_prepare_init_cache carapace carapace _carapace
      [[ -r "$VEDUP_INIT_CACHE_FILE" ]] && source "$VEDUP_INIT_CACHE_FILE"
    fi
    vedup_prepare_init_cache starship starship init zsh
    [[ -r "$VEDUP_INIT_CACHE_FILE" ]] && source "$VEDUP_INIT_CACHE_FILE"
  else
    # A partially linked configuration remains usable, although Vedup's normal
    # installation always provides the cache helper.
    (( $+commands[mise] )) && eval "$(mise activate zsh)"
    (( $+commands[zoxide] )) && eval "$(zoxide init zsh)"
    (( $+commands[fzf] )) && eval "$(fzf --zsh 2>/dev/null)"
    if (( $+commands[carapace] )); then
      export CARAPACE_BRIDGES='zsh'
      source <(carapace _carapace)
    fi
    (( $+commands[starship] )) && eval "$(starship init zsh)"
  fi

  # Load every modular file, including user-added modules, while keeping the
  # early and final modules in their required positions.
  for config_path in "$VEDUP_ZSH_MODULES"/*.sh(N); do
    case "${config_path:t}" in
      env.sh|completions.sh|init-cache.sh|plugins.sh) continue ;;
    esac
    source "$config_path"
  done

  [[ -r "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"
  # Widgets and syntax highlighting must load after every other integration.
  [[ -r "$VEDUP_ZSH_MODULES/plugins.sh" ]] && source "$VEDUP_ZSH_MODULES/plugins.sh"
fi

unset config_path VEDUP_INIT_CACHE_FILE VEDUP_ZSH_REFRESH_CACHE

# Keep the startup file successful when optional local configuration is absent.
true
