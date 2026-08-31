#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
TMP="$TEST_TMP_ROOT/readonly"; mkdir -p "$TMP/mockbin"
: > "$TMP/mutations"

# Commands that SYSdiag must never invoke as active operations.
for cmd in mount umount reboot shutdown kill pkill killall apt apt-get dnf yum zypper pacman; do
  cat > "$TMP/mockbin/$cmd" <<MOCK
#!/usr/bin/env bash
printf '%s %s\\n' '$cmd' "\$*" >> '$TMP/mutations'
exit 99
MOCK
  chmod +x "$TMP/mockbin/$cmd"
done

real_systemctl="$(command -v systemctl || true)"
cat > "$TMP/mockbin/systemctl" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
  start|stop|restart|reload|enable|disable|mask|unmask|reset-failed|daemon-reload|daemon-reexec|isolate|poweroff|reboot|halt|suspend|hibernate)
    printf 'systemctl %s\\n' "\$*" >> '$TMP/mutations'; exit 99 ;;
esac
if [[ -n '$real_systemctl' ]]; then exec '$real_systemctl' "\$@"; fi
exit 1
MOCK
chmod +x "$TMP/mockbin/systemctl"


for runtime in docker podman; do
  real="$(command -v "$runtime" || true)"
  cat > "$TMP/mockbin/$runtime" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
  start|stop|restart|kill|rm|rmi|run|create|exec|update|pause|unpause|pull|push|build|commit|rename)
    printf '$runtime %s\n' "\$*" >> '$TMP/mutations'; exit 99 ;;
  system)
    [[ "\${2:-}" == prune ]] && { printf '$runtime %s\n' "\$*" >> '$TMP/mutations'; exit 99; } ;;
  container|image|volume|network)
    case "\${2:-}" in rm|prune|create|connect|disconnect) printf '$runtime %s\n' "\$*" >> '$TMP/mutations'; exit 99 ;; esac ;;
esac
if [[ -n '$real' ]]; then exec '$real' "\$@"; fi
exit 1
MOCK
  chmod +x "$TMP/mockbin/$runtime"
done


for cli in kubectl oc; do
  cat > "$TMP/mockbin/$cli" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
  apply|create|delete|patch|edit|replace|exec|debug|port-forward|cp|scale|autoscale|cordon|uncordon|drain|taint)
    printf '$cli %s\n' "\$*" >> '$TMP/mutations'; exit 99 ;;
  rollout)
    case "\${2:-}" in restart|undo) printf '$cli %s\n' "\$*" >> '$TMP/mutations'; exit 99 ;; esac ;;
  adm)
    case "\${2:-}" in must-gather|drain|cordon|prune|upgrade) printf '$cli %s\n' "\$*" >> '$TMP/mutations'; exit 99 ;; esac ;;
esac
exit 1
MOCK
  chmod +x "$TMP/mockbin/$cli"
done

real_sysctl="$(command -v sysctl || true)"
cat > "$TMP/mockbin/sysctl" <<MOCK
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == '-w' || "\$a" == *=* ]]; then
    printf 'sysctl %s\\n' "\$*" >> '$TMP/mutations'; exit 99
  fi
done
if [[ -n '$real_sysctl' ]]; then exec '$real_sysctl' "\$@"; fi
exit 1
MOCK
chmod +x "$TMP/mockbin/sysctl"

SYSDIAG_TRUSTED_PATH="$TMP/mockbin:/usr/bin:/bin" PATH="$TMP/mockbin:$PATH" "$BASE_DIR/sysdiag.sh" --all --no-color > "$TMP/all.txt"
[[ ! -s "$TMP/mutations" ]] || fail "SYSdiag intentó una acción mutante: $(cat "$TMP/mutations")"
assert_grep '^RESUMEN PRIORIZADO$' "$TMP/all.txt"
assert_grep 'Boot / arranque' "$TMP/all.txt"
assert_grep 'Contenedores / runtime' "$TMP/all.txt"

# Defensa en profundidad del propio collector: las familias mutantes se bloquean
# incluso antes de alcanzar los mocks/binarios del sistema.
( source "$BASE_DIR/lib/common.sh"; readonly_command_guard systemctl status sshd ) || fail 'guard bloqueó systemctl status'
if ( source "$BASE_DIR/lib/common.sh"; readonly_command_guard systemctl restart sshd ); then fail 'guard permitió systemctl restart'; fi
if ( source "$BASE_DIR/lib/common.sh"; readonly_command_guard env LC_ALL=C systemctl restart sshd ); then fail 'guard permitió systemctl restart env-wrapped'; fi
if ( source "$BASE_DIR/lib/common.sh"; readonly_command_guard env -u X systemctl restart sshd ); then fail 'guard permitió env con opciones no autorizadas'; fi
if ( source "$BASE_DIR/lib/common.sh"; readonly_command_guard kubectl delete pod x ); then fail 'guard permitió kubectl delete'; fi
if ( source "$BASE_DIR/lib/common.sh"; readonly_command_guard docker rm x ); then fail 'guard permitió docker rm'; fi
if ( source "$BASE_DIR/lib/common.sh"; readonly_command_guard sysctl -w vm.swappiness=1 ); then fail 'guard permitió sysctl -w'; fi
if ! ( source "$BASE_DIR/lib/common.sh"; readonly_shell_guard 'find /var/log -type f 2>/dev/null | head -n 1 >/dev/null' ); then fail 'guard shell bloqueó pipeline read-only'; fi
if ( source "$BASE_DIR/lib/common.sh"; readonly_shell_guard 'echo x > /etc/sysdiag-test' ); then fail 'guard shell permitió redirección de escritura'; fi
if ( source "$BASE_DIR/lib/common.sh"; readonly_shell_guard 'kubectl delete pod x' ); then fail 'guard shell permitió kubectl delete'; fi

pass readonly
