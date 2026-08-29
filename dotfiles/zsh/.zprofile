# Homebrew publishes login-session variables on macOS. Keep this file quiet and
# leave terminal features to .zshrc.
if [[ "$OSTYPE" == darwin* ]]; then
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  # brew shellenv rewrites PATH, so restore Vedup's pinned tools in front.
  typeset -U path PATH
  path=("$HOME/.local/share/mise/shims" "$HOME/.local/bin" $path)
  export PATH
fi
