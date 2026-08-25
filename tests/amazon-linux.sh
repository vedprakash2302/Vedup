#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
INVENTORY="$TEST_ROOT/inventory.tsv"
printf 'command\tcurl\n' > "$INVENTORY"

for script in "$REPO_ROOT"/bin/* "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/lib/platforms/*.sh; do
  [ -f "$script" ] && bash -n "$script"
done

for arch in x64 arm64; do
  output="$(HOME="$TEST_ROOT/home-$arch" VEDUP_TEST_INVENTORY_FILE="$INVENTORY" \
    VEDUP_TEST_OS=linux VEDUP_TEST_DISTRO=amzn VEDUP_TEST_DISTRO_VERSION=2023 \
    VEDUP_TEST_ARCH="$arch" "$REPO_ROOT/bin/setup" --profile server --dry-run \
      --no-shell-change --no-verify --skip-plugins 2>&1)"
  [[ "$output" == *"dnf install -y"* || "$output" == *"yum install -y"* ]]
  [[ "$output" == *"findutils"* ]]
  [[ "$output" != *" ca-certificates curl findutils"* ]]
  [[ "$output" != *"dnf upgrade"* && "$output" != *"yum update"* ]]
  [[ "$output" == *"Workflow: fresh"* ]]
done

if HOME="$TEST_ROOT/home-al2" VEDUP_TEST_OS=linux VEDUP_TEST_DISTRO=amzn \
  VEDUP_TEST_DISTRO_VERSION=2 VEDUP_TEST_ARCH=x64 \
  "$REPO_ROOT/bin/setup" --profile server --dry-run --no-shell-change >/dev/null 2>&1; then
  printf '[test] FAIL: end-of-support Amazon Linux 2 was accepted\n' >&2
  exit 1
fi

printf '[test] Amazon Linux 2023 provider passed on simulated x64 and arm64 inventories\n'
