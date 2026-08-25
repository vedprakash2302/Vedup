# Pinned by Vedup's installer; never download code during shell startup.
plugin_root="${VEDUP_ZSH_PLUGIN_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/vedup/zsh/plugins}"

# Alias providers load before zsh-you-should-use inspects entered commands.
[[ -r "$plugin_root/git-alias/git-alias.plugin.zsh" ]] && \
  source "$plugin_root/git-alias/git-alias.plugin.zsh"
[[ -r "$plugin_root/zsh-you-should-use/you-should-use.plugin.zsh" ]] && \
  source "$plugin_root/zsh-you-should-use/you-should-use.plugin.zsh"

[[ -r "$plugin_root/zsh-autosuggestions/zsh-autosuggestions.zsh" ]] && \
  source "$plugin_root/zsh-autosuggestions/zsh-autosuggestions.zsh"
[[ -r "$plugin_root/zsh-history-substring-search/zsh-history-substring-search.zsh" ]] && \
  source "$plugin_root/zsh-history-substring-search/zsh-history-substring-search.zsh"

if (( $+widgets[history-substring-search-up] )); then
  bindkey -M emacs '^[[A' history-substring-search-up
  bindkey -M emacs '^[[B' history-substring-search-down
  bindkey -M viins '^[[A' history-substring-search-up
  bindkey -M viins '^[[B' history-substring-search-down
fi

# The highlighter must be the final sourced plugin so it can wrap every widget.
[[ -r "$plugin_root/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]] && \
  source "$plugin_root/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"

unset plugin_root
