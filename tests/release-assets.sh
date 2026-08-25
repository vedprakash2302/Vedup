#!/usr/bin/env bash

set -Eeuo pipefail

BOOTSTRAP="$1"
ARCHIVE="$2"
CHECKSUMS="$3"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

(cd "$(dirname "$CHECKSUMS")" && sha256sum -c "$(basename "$CHECKSUMS")")
tar -tzf "$ARCHIVE" | grep '/bin/setup$' >/dev/null
tar -tzf "$ARCHIVE" | grep '/bin/doctor$' >/dev/null
tar -tzf "$ARCHIVE" | grep '/bin/update$' >/dev/null
tar -tzf "$ARCHIVE" | grep '/bin/vedup$' >/dev/null
tar -tzf "$ARCHIVE" | grep '/.vedup-manifest.sha256$' >/dev/null
tar -tzf "$ARCHIVE" | grep '/repository.env$' >/dev/null
grep -Eq '^VEDUP_RELEASE_REF="v[^"]+"' "$BOOTSTRAP"
grep -Eq '^VEDUP_RELEASE_COMMIT="[0-9a-f]{40}"' "$BOOTSTRAP"
grep -Eq '^VEDUP_ARCHIVE_SHA256="[0-9a-f]{64}"' "$BOOTSTRAP"
grep -Eq '^VEDUP_REPOSITORY="\$\{VEDUP_REPOSITORY:-[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\}"' "$BOOTSTRAP"
if grep -q '__VEDUP_' "$BOOTSTRAP"; then exit 1; fi
if grep -Eq 'git (clone|fetch|checkout)' "$BOOTSTRAP"; then exit 1; fi

tar -xzf "$ARCHIVE" -C "$TEST_ROOT"
test -x "$TEST_ROOT"/*/bin/setup
test -x "$TEST_ROOT"/*/bin/doctor
test -x "$TEST_ROOT"/*/bin/update
test -x "$TEST_ROOT"/*/bin/vedup
test -r "$TEST_ROOT"/*/repository.env
grep -Fxq 'VEDUP_DEFAULT_REPOSITORY="vedprakash2302/Vedup"' "$TEST_ROOT"/*/repository.env
(cd "$TEST_ROOT"/* && sha256sum -c .vedup-manifest.sha256 >/dev/null)
printf '[test] release assets verified\n'
