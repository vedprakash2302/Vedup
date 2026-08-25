alias lg=lazygit
alias k=kubectl

if (( $+commands[eza] )); then
  alias ls='eza --group-directories-first --icons=auto'
  alias ll='ls -lh --git'
  alias la='ll -a'
  alias tree='ll --tree --level=2'
fi
