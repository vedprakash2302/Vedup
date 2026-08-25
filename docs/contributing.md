# Contributing and releasing

Remote `AUTHOR_MODE` is unsupported. Work from a separate clone:

```sh
git clone https://github.com/vedprakash2302/Vedup.git
cd Vedup
./bin/install
```

Validate changes with:

```sh
./tests/test.sh
./tests/amazon-linux.sh
./bin/setup --dry-run
./scripts/scan-secrets --all
```

Enable the repository-owned pre-commit guard once per clone:

```sh
git config core.hooksPath .githooks
```

The hook runs the same pinned, checksum-verified Gitleaks scanner against the
staged patch. CI scans both the current tree and the complete reachable Git
history with redaction enabled. If a credential is ever suspected, revoke or
rotate it first; deleting it from a later commit is not sufficient.

The test suite isolates HOME, state, cache, inventory, and package-manager
fixtures. It covers fresh, partial, externally configured, managed and
interrupted states, plus the invariant that a second safe sync is a no-op.

The disposable canary workflow uses GitHub-hosted macOS and Linux runners; no
spare Mac is required. Before a release, run it from Actions or with:

```sh
gh workflow run canary.yml --ref main -f ref=main
```

A version tag triggers the release workflow. The workflow reruns macOS, Ubuntu,
and Amazon Linux validation plus disposable two-run canaries before it can
build or publish anything. The archive contains a per-file checksum manifest;
bootstrap embeds the archive commit and checksum and validates both layers.
