# Durable, shared history without repeated or whitespace-only entries.
setopt share_history
setopt hist_expire_dups_first
setopt hist_reduce_blanks
setopt inc_append_history
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_ignore_space

# Predictable completion menus in both Emacs and vi insert keymaps.
setopt auto_list
setopt auto_menu
setopt always_to_end

bindkey -v
bindkey -M emacs '^I' expand-or-complete-prefix
bindkey -M viins '^I' expand-or-complete-prefix

zstyle ':completion:*:git:*' group-order 'main commands' 'alias commands' 'external commands'
zstyle ':completion:*' format $'\e[2;37mCompleting %d\e[m'
