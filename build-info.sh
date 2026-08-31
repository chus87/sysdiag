#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"
version="$(sed -n 's/^SYS_DIAG_VERSION="\([^"]*\)"/\1/p' lib/version.sh | head -n1)"
schema="$(sed -n 's/^SYS_DIAG_JSON_SCHEMA_VERSION="\([^"]*\)"/\1/p' lib/json.sh | head -n1)"
collector="$(sha256sum sysdiag-standalone.sh | awk '{print $1}')"
commit="${COMMIT:-$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)}"
tag="${TAG:-$(git describe --tags --exact-match HEAD 2>/dev/null || echo untagged)}"
build_date="${BUILD_DATE:-unknown}"
{
  printf 'SYSdiag %s\n' "$version"
  printf 'Author: Chus (GitHub: chus87)\n'
  printf 'License: Apache-2.0\n'
  printf 'Schema: %s\n' "$schema"
  printf 'Go toolchain: %s\n' "$(go version 2>/dev/null || echo unavailable)"
  printf 'Targets: linux/amd64, linux/arm64\n'
  printf 'SOURCE_DATE_EPOCH: %s\n' "${SOURCE_DATE_EPOCH:-not-set}"
  printf 'Commit: %s\n' "$commit"
  printf 'Tag: %s\n' "$tag"
  printf 'Build date: %s\n' "$build_date"
  printf 'Collector SHA256: %s\n' "$collector"
  printf '\nArtifacts:\n'
  sha256sum sysdiag-standalone.sh bin/sysdiag-linux-amd64 bin/sysdiag-linux-arm64
} > BUILDINFO.txt
