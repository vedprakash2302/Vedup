# Vedup Neovim configuration

This intentionally small configuration uses [LazyVim](https://lazyvim.github.io/)
as its plugin distribution. Vedup installs the pinned Neovim runtime; Lazy
downloads plugins on first interactive launch and then follows `lazy-lock.json`.

Put personal overrides in `lua/plugins/`. Keep this directory free of secrets:
configuration saved by `vedup save` may be published to a public repository.
