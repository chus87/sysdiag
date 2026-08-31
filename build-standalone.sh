#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$BASE_DIR/sysdiag-standalone.sh"

# Read the version from the same source used by the modular launcher.
# shellcheck source=lib/version.sh
source "$BASE_DIR/lib/version.sh"

FILES=(
  lib/version.sh
  lib/common.sh
  lib/output.sh
  lib/scoring.sh
  lib/sampler.sh
  modules/system.sh
  modules/cpu.sh
  modules/processes.sh
  modules/memory.sh
  modules/io.sh
  modules/filesystem.sh
  modules/network.sh
  modules/logging.sh
  modules/recent_events.sh
  modules/systemd_services.sh
  modules/boot.sh
  modules/containers.sh
  modules/kubernetes.sh
  modules/reference.sh
  lib/json.sh
  lib/cli.sh
)

{
  printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail' 'BASE_DIR="$(pwd)"' ''
  for f in "${FILES[@]}"; do
    [[ -r "$BASE_DIR/$f" ]] || { printf 'Falta %s\n' "$f" >&2; exit 1; }
    printf '\n# ===== %s =====\n\n' "$f"
    cat "$BASE_DIR/$f"
  done
  printf '\nmain "$@"\n'
} > "$OUT"
chmod +x "$OUT"
mkdir -p "$BASE_DIR/internal/assets"
cp "$OUT" "$BASE_DIR/internal/assets/sysdiag-standalone.sh"
printf 'Generado SYSdiag %s: %s\n' "$SYS_DIAG_VERSION" "$OUT"
