#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP_ROOT="${TEST_TMP_ROOT:-$(mktemp -d)}"
export BASE_DIR TEST_TMP_ROOT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
assert_grep() { grep -q -- "$1" "$2" || fail "no aparece [$1] en $2"; }
assert_no_grep() { ! grep -q -- "$1" "$2" || fail "aparece inesperadamente [$1] en $2"; }
