# Security policy

Vedup is public and must never contain credentials, private keys, access
tokens, authenticated URLs, or machine-local secret files.

## Reporting a security problem

Do not open a public issue containing a credential or exploit output that
includes one. Contact the repository owner privately through GitHub instead.

If a credential may have reached Git or CI, revoke or rotate it first. Removing
the current file is not sufficient because Git history and workflow logs may
still contain the value.

## Repository rules

- Use placeholders or environment-variable references in tracked examples.
- Keep real values in ignored `*.local` or `.env` files outside Vedup's managed
  capture set.
- Run `./scripts/scan-secrets --all` before committing.
- Never bypass the secret scan, required CI checks, or GitHub push protection.
- `vedup save` may open a draft pull request, but it never merges or releases.

Scanner output is always redacted. A positive result blocks publication until
the credential is revoked and the repository and reachable history are clean.
