# Safety, state, and recovery

Vedup creates a complete plan before requesting administrator approval. Each
resource is classified as Vedup-managed, external, or an unmanaged conflict;
each action is install, update, keep, configure, review, or conflict.

Validated data lives under `~/.local/state/vedup`. Choices and ownership are TSV
data and are never sourced as shell code. Each mutating run has an execution
journal in `transactions/`, allowing an interrupted run to be re-inventoried
and resumed.

Verified releases live under `~/.local/share/vedup/releases/`. The `current`
link selects the CLI and may advance during `vedup update`; `applied` selects
the machine policy and advances with committed state only after configuration
and health checks pass. Both pointers roll back together if sync fails.

Managed configuration uses a writable three-way workspace:

```text
~/.local/share/vedup/config/base/
~/.local/share/vedup/config/worktree/
```

Local-only edits are preserved, incoming-only edits are applied, and files
changed on both sides are reported instead of overwritten. Stow operations are
preflighted and previous links or conflicting files are restored on immediate
failure. Backups are indexed under `~/.local/state/vedup/backups/`.

macOS preference work records touched keys, their previous values, and whether
they existed. Failure restores previous values and removes newly introduced
keys. The latest snapshot can be restored from `vedup advanced`.

Vedup asks for sudo only when the plan needs it. Passwordless sudo is used when
the machine permits it; otherwise sudo displays one normal password prompt.
Vedup never reads, stores, invents, or changes that password or sudo policy.

Package managers cannot reliably roll back installations. Their changes are
therefore additive, missing-only, and resumable. Run `vedup sync` to resume an
interrupted setup; use the one-liner to recover the CLI itself.
