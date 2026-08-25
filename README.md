# Vedup

Vedup is a safe machine bootstrap and development-environment synchronizer for
macOS and Linux. It inventories first, presents one understandable plan, and
changes only missing or explicitly Vedup-managed resources.

## Start here

```bash
bash -c "$(curl -fsSL https://github.com/vedprakash2302/Vedup/releases/latest/download/bootstrap)"
```

The same command works on a fresh machine and an existing Vedup machine. In an
interactive terminal, choose **Set up this machine** for the recommended plan
or **Customize** to change application and tooling bundles.

Supported platforms:

- macOS on Apple Silicon and Intel;
- Ubuntu 22.04 and 24.04 on x86_64 or ARM64;
- Ubuntu 22.04 and 24.04 under WSL2;
- Amazon Linux 2023 on x86_64 or ARM64.

## Daily use

Run `vedup` for the home menu. Direct commands are also available:

```bash
vedup sync          # apply missing tools and managed configuration changes
vedup customize     # change saved bundles and application selections
vedup update        # update only the Vedup CLI
vedup save          # review local configuration/app changes for capture
vedup apps update   # review macOS GUI updates
vedup doctor        # diagnose the active installation
vedup advanced      # high-impact macOS settings
```

`vedup update` verifies an immutable release and advances only the CLI pointer.
It never installs applications or changes the shell, dotfiles, runtimes, or
system preferences. `vedup sync` is always a separate action.

## What Vedup manages

The terminal profile includes Zsh, tmux, Neovim, Starship, Mise-managed Node
and Python, GitHub CLI, lazygit, modern search/file tools, completions,
autosuggestions, syntax highlighting, history search, Git aliases, and pinned
Zsh/tmux plugins.

The macOS workstation bundle is declared once in
[profiles/macos/apps.tsv](profiles/macos/apps.tsv). It includes Ghostty, Zed,
Cursor, Docker Desktop, Chrome, ChatGPT, Dia, Raycast, Aerospace, Borders,
Shottr, Jump Desktop, Bitwarden CLI, Focus, Linear, PDFgear, T3 Code Nightly,
and the tracked supporting applications and font.

## Safety model

- Planning happens before sudo or mutation.
- Compatible external software is retained rather than adopted or replaced.
- General Homebrew, APT, DNF/YUM, App Store and operating-system upgrades are
  outside normal synchronization.
- Existing GUI applications are upgraded only through explicit review.
- Git credentials, `.gitconfig`, credential helpers and Keychain permissions
  are never managed.
- Dotfiles and macOS preferences are backed up and restored after a failed
  configuration transaction.
- The `current` CLI release and successfully `applied` machine policy are
  separate, so updating Vedup cannot silently change runtimes.

Installation uses a compact progress dashboard with five recent activity lines.
Detailed logs are stored under `~/.local/state/vedup/logs/`.

## Documentation

- [Automation](docs/automation.md)
- [Safety and recovery](docs/safety.md)
- [Architecture](docs/architecture.md)
- [Contributing and releases](docs/contributing.md)

Vedup is distributed under the [MIT License](LICENSE). Third-party components
and configuration sources are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
