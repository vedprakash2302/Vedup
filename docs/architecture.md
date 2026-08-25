# Architecture

The published bootstrap contains an immutable release tag, commit, and archive
checksum. It downloads with curl, verifies SHA-256, extracts to a pending
release directory, and starts that release directly. Git is not a bootstrap
dependency.

The friendly interface is `bin/install`; the automation engine is `bin/setup`.
Both feed the same inventory and planner. `bin/vedup` is the stable command
dispatcher installed into `~/.local/bin`.

After the first installation, `vedup update` reads the published bootstrap's
release metadata, downloads and verifies the immutable archive and its file
manifest, and atomically advances the `current` CLI pointer. The separate
`applied` pointer continues to supply Mise and shell policy until a successful
sync advances it. Updating deliberately does not run setup or modify the machine;
`vedup sync` is the separate configuration action. The long one-liner is only
the initial bootstrap and recovery entry point.

Important data sources:

- `profiles/macos/apps.tsv`: one deduplicated Mac application manifest;
- `mise.toml` and `versions.env`: pinned tools and plugins;
- `dotfiles/`: managed configuration templates;
- `~/.local/state/vedup/choices.tsv`: bundle defaults and per-app overrides;
- `~/.local/state/vedup/resources.tsv`: last committed ownership inventory.

Bundle defaults make choices forward-compatible: a newly added app follows its
bundle unless the user has an explicit per-app override. Install providers
consume the filtered selection, not the raw manifest.

Normal sync converges only missing resources, pinned Vedup ownership, and
configuration drift. Application upgrades and high-impact macOS settings use
scoped executors and cannot accidentally run a full sync. Capture writes an
isolated branch and, when requested, opens only a draft pull request.
