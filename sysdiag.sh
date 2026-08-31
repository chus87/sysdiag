#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
arch="$(uname -m 2>/dev/null || true)"
case "$arch" in
  x86_64|amd64) bin="$BASE_DIR/bin/sysdiag-linux-amd64" ;;
  aarch64|arm64) bin="$BASE_DIR/bin/sysdiag-linux-arm64" ;;
  *) bin="" ;;
esac

if [[ -n "$bin" && -x "$bin" ]]; then
  exec "$bin" "$@"
fi

# Development/source-tree fallback: compile the Go entrypoint when the pinned
# toolchain is available. Production packages normally never reach this path.
if command -v go >/dev/null 2>&1 && [[ -f "$BASE_DIR/go.mod" ]]; then
  cd "$BASE_DIR"
  exec go run ./cmd/sysdiag "$@"
fi

# Unsupported architectures can still use the self-contained compatibility
# collector. When package checksums are present, refuse a modified fallback.
fallback="$BASE_DIR/sysdiag-standalone.sh"
[[ -f "$fallback" ]] || { printf 'ERROR: no hay binario Go compatible ni standalone Bash disponible.\n' >&2; exit 1; }
if [[ -f "$BASE_DIR/SHA256SUMS" ]] && command -v sha256sum >/dev/null 2>&1; then
  expected="$(awk '$2=="sysdiag-standalone.sh" {print $1; exit}' "$BASE_DIR/SHA256SUMS")"
  if [[ -n "$expected" ]]; then
    actual="$(sha256sum "$fallback" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || { printf 'ERROR: el standalone Bash no supera la verificación de integridad.\n' >&2; exit 1; }
  fi
fi
printf 'Aviso: binario Go no disponible para esta arquitectura; se usa el standalone Bash de compatibilidad.\n' >&2
exec /bin/bash "$fallback" "$@"
