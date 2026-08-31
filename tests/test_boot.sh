#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
TMP="$TEST_TMP_ROOT/boot"; mkdir -p "$TMP/mockbin" "$TMP/proc/1" "$TMP/etc"
printf 'systemd\n' > "$TMP/proc/1/comm"
printf 'BOOT_IMAGE=/vmlinuz root=UUID=ROOT ro quiet\n' > "$TMP/proc/cmdline"
cat > "$TMP/proc/self.mountinfo" <<'MI'
24 1 0:22 / / rw,relatime - ext4 /dev/mapper/vg-root rw
MI

cat > "$TMP/etc/fstab" <<'FSTAB'
# valid root
UUID=ROOT / ext4 defaults 0 1
UUID=MISSING /data ext4 defaults 0 2
UUID=NOFAIL /optional ext4 defaults,nofail 0 2
UUID=NOAUTO /manual ext4 defaults,noauto 0 2
UUID=AUTO /lazy ext4 defaults,x-systemd.automount 0 2
server:/share /mnt/share nfs defaults 0 0
UUID=ROOT /dup ext4 defaults 0 2
UUID=ROOT /dup ext4 defaults 0 2
bad-line-only-two fields
FSTAB

cat > "$TMP/mockbin/blkid" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *'UUID=ROOT'*) echo /dev/mapper/vg-root; exit 0 ;;
  *'UUID=MISSING'*|*'UUID=NOFAIL'*|*'UUID=NOAUTO'*|*'UUID=AUTO'*) exit 2 ;;
  *) exit 2 ;;
esac
MOCK
cat > "$TMP/mockbin/findmnt" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  '-n -o SOURCE /') echo /dev/mapper/vg-root ;;
  '-n -o FSTYPE /') echo ext4 ;;
  *) exit 0 ;;
esac
MOCK
cat > "$TMP/mockbin/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  '--failed --type=mount --no-legend --plain --no-pager')
    echo 'data.mount loaded failed failed /data'; exit 0 ;;
  *) exit 0 ;;
esac
MOCK
cat > "$TMP/mockbin/systemd-analyze" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  'time') echo 'Startup finished in 2.000s (kernel) + 5.000s (userspace) = 7.000s' ;;
  'blame --no-pager') printf '4.000s data.mount\n2.000s network-online.target\n' ;;
  'critical-chain --no-pager') printf 'multi-user.target @7s\n└─data.mount @2s +4s\n' ;;
  *) exit 0 ;;
esac
MOCK
cat > "$TMP/mockbin/journalctl" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  '--list-boots --no-pager') printf '%s\n' '-1 abc old' '0 def current' ;;
  *'-k -b -p warning'*) printf '%s\n' 'nvme0: I/O timeout' ;;
  *'-b -p warning'*) cat <<'OUT'
systemd[1]: Timed out waiting for device /dev/disk/by-uuid/MISSING.
systemd[1]: Failed to mount /data.
systemd[1]: Entered emergency mode.
systemd-fsck[99]: filesystem check failed
OUT
    ;;
  *) exit 0 ;;
esac
MOCK
cat > "$TMP/mockbin/systemd-detect-virt" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == '--container' ]] && exit 1
exit 1
MOCK
chmod +x "$TMP/mockbin"/*

(
  export PATH="$TMP/mockbin:$PATH" BOOT_PROC_ROOT="$TMP/proc" BOOT_ETC_ROOT="$TMP/etc" BOOT_FORCE_CONTEXT=host
  source "$BASE_DIR/lib/common.sh"; source "$BASE_DIR/lib/output.sh"; source "$BASE_DIR/lib/scoring.sh"; source "$BASE_DIR/modules/boot.sh"
  VERBOSE=1; EXPLAIN=1; NO_COLOR=1; init_output; init_scoring
  collect_boot; analyze_boot
  [[ "$BOOT_CONTEXT_REPRESENTATIVE" == 1 ]]
  [[ "$BOOT_ROOT_ARG" == UUID=ROOT ]]
  [[ "$BOOT_ROOT_SOURCE" == /dev/mapper/vg-root ]]
  [[ "$BOOT_FSTAB_INVALID_COUNT" == 1 ]]
  [[ "$BOOT_FSTAB_DUPLICATE_MOUNT_COUNT" == 1 ]]
  [[ "$BOOT_FSTAB_MISSING_REQUIRED" == 1 ]]
  [[ "$BOOT_FSTAB_MISSING_NOFAIL" == 1 ]]
  [[ "$BOOT_FSTAB_MISSING_NOAUTO" == 1 ]]
  [[ "$BOOT_FSTAB_MISSING_AUTOMOUNT" == 1 ]]
  [[ "$BOOT_FSTAB_REMOTE_COUNT" == 1 ]]
  [[ "$BOOT_FAILED_MOUNTS_COUNT" == 1 ]]
  [[ "$BOOT_ANALYZE_TIME_VALID" == 1 && "$BOOT_ANALYZE_BLAME_VALID" == 1 && "$BOOT_CRITICAL_CHAIN_VALID" == 1 ]]
  [[ "$BOOT_JOURNAL_BOOT_COUNT" == 2 && "$BOOT_PREVIOUS_BOOT_AVAILABLE" == sí ]]
  (( BOOT_EMERGENCY_HINTS > 0 && BOOT_DEVICE_TIMEOUT_HINTS > 0 && BOOT_FSCK_HINTS > 0 && BOOT_MOUNT_FAILURE_HINTS > 0 && BOOT_IO_KERNEL_HINTS > 0 ))
  (( SCORE[boot] >= 12 ))
  printf '%s\n' "${EVIDENCE[@]}" | grep -q BOOT_FSTAB_MISSING_REQUIRED
  printf '%s\n' "${EVIDENCE[@]}" | grep -q BOOT_FAILED_MOUNTS
  print_boot > "$TMP/boot-print.txt"
)
for p in '^BOOT / ARRANQUE$' 'Referencias obligatorias ausentes:.*1' 'Ausentes con nofail:.*1' 'Critical chain' 'duración ≠ retraso causal'; do assert_grep "$p" "$TMP/boot-print.txt"; done
assert_no_grep $'\033' "$TMP/boot-print.txt"

# Container context: do not treat host kernel cmdline and container root as one boot chain.
cat > "$TMP/mockbin/systemd-detect-virt" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == '--container' ]] && { echo docker; exit 0; }
exit 1
MOCK
chmod +x "$TMP/mockbin/systemd-detect-virt"
(
  export PATH="$TMP/mockbin:$PATH" BOOT_PROC_ROOT="$TMP/proc" BOOT_ETC_ROOT="$TMP/etc" BOOT_FORCE_CONTEXT=container
  source "$BASE_DIR/lib/common.sh"; source "$BASE_DIR/lib/scoring.sh"; source "$BASE_DIR/modules/boot.sh"
  init_scoring; collect_boot; analyze_boot
  [[ "$BOOT_CONTEXT" == contenedor && "$BOOT_CONTEXT_REPRESENTATIVE" == 0 ]]
  printf '%s\n' "${LIMITATIONS[@]}" | grep -q 'contenedor'
)

# Reuse known failed logging/systemd access instead of repeating failing queries.
mkdir -p "$TMP/reusebin"
cat > "$TMP/reusebin/journalctl" <<'MOCK'
#!/usr/bin/env bash
echo CALLED_JOURNAL >&2; exit 99
MOCK
cat > "$TMP/reusebin/systemctl" <<'MOCK'
#!/usr/bin/env bash
echo CALLED_SYSTEMCTL >&2; exit 99
MOCK
cp "$TMP/mockbin/findmnt" "$TMP/reusebin/findmnt"
cp "$TMP/mockbin/blkid" "$TMP/reusebin/blkid"
cat > "$TMP/reusebin/systemd-detect-virt" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "$TMP/reusebin"/*
(
  export PATH="$TMP/reusebin:$PATH" BOOT_PROC_ROOT="$TMP/proc" BOOT_ETC_ROOT="$TMP/etc" BOOT_FORCE_CONTEXT=host
  export LOGGING_COLLECTED=1 JOURNAL_ACCESS=inaccesible SYSTEMD_PID1=1 SYSTEMD_ACCESS=timeout
  source "$BASE_DIR/lib/common.sh"; source "$BASE_DIR/lib/scoring.sh"; source "$BASE_DIR/modules/boot.sh"
  init_scoring
  collect_boot 2>"$TMP/reuse.err"
  ! grep -q CALLED_JOURNAL "$TMP/reuse.err"
  ! grep -q CALLED_SYSTEMCTL "$TMP/reuse.err"
  [[ "$BOOT_JOURNAL_BOOT_COUNT" == n/d ]]
)

pass boot
