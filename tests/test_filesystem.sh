#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
TMP="$TEST_TMP_ROOT/filesystem"; mkdir -p "$TMP/mockbin"

cat > "$TMP/mockbin/df" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *-PTh*) cat <<'OUT'
Filesystem Type Size Used Avail Use% Mounted on
/dev/sda1 ext4 100G 20G 80G 20% /
/home/test/App.AppImage fuse.AppImage 200M 200M 0 100% /tmp/.mount_AppABC
OUT
;;
  *-PTi*) cat <<'OUT'
Filesystem Type Inodes IUsed IFree IUse% Mounted on
/dev/sda1 ext4 100000 20000 80000 20% /
/home/test/App.AppImage fuse.AppImage 1000 1000 0 100% /tmp/.mount_AppABC
OUT
;;
  *) exec /bin/df "$@" ;;
esac
MOCK
chmod +x "$TMP/mockbin/df"
PATH="$TMP/mockbin:$PATH" "$BASE_DIR/sysdiag-legacy.sh" --section filesystem --verbose --no-color > "$TMP/fs.txt"
assert_grep 'FS >=85% / >=95%:.*0 / 0' "$TMP/fs.txt"
assert_grep 'Inodos >=85% / >=95%:.*0 / 0' "$TMP/fs.txt"
assert_grep 'Imágenes RO ignoradas:.*1 ' "$TMP/fs.txt"

(
  source "$BASE_DIR/lib/common.sh"; source "$BASE_DIR/modules/filesystem.sh"
  RAW=$'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NLINK NODE NAME\njava 1 u 3w REG 8,1 104857600 0 123 /var/log/a.log (deleted)\njava 1 u 4w REG 8,1 104857600 0 123 /var/log/a.log (deleted)\nx 2 u 5u REG 0,20 65536 0 999 /memfd:foo (deleted)'
  parse_deleted_open_lsof "$RAW"
  [[ "$DELETED_OPEN_DESCRIPTOR_COUNT" == 3 && "$DELETED_OPEN_UNIQUE_COUNT" == 2 ]]
  [[ "$DELETED_OPEN_DISK_UNIQUE_COUNT" == 1 && "$DELETED_OPEN_EPHEMERAL_UNIQUE_COUNT" == 1 ]]
  [[ "$DELETED_OPEN_RETAINED_BYTES" == 104857600 ]]
)

pass filesystem
