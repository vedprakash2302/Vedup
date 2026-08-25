# Automation

Interactive users need only the release one-liner. Flags are for scripts, CI,
and deliberate unattended setup.

Pass them after `--`:

```sh
bash -c "$(curl -fsSL https://github.com/vedprakash2302/Vedup/releases/latest/download/bootstrap)" -- \
  --non-interactive --profile server --with-aws
```

Available flags:

```text
--profile auto|server|workstation
--with-aws | --without-aws
--with-docker | --without-docker
--with-personal-apps | --without-personal-apps
--upgrade-apps
--dry-run
--verbose
--jobs 1..8
--interactive | --non-interactive
--macos-defaults | --no-macos-defaults
--minimal-dock | --no-minimal-dock
--keyboard-shortcuts | --no-keyboard-shortcuts
--experimental-macos-defaults | --no-experimental-macos-defaults
--shell-change | --no-shell-change
--no-verify
```

`--upgrade-apps` is the only unattended opt-in for upgrading existing GUI
applications. Vedup never performs a general package-manager or OS upgrade.

Use `vedup help --automation` after installation for the same reference.
