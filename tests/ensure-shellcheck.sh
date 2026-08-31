#!/usr/bin/env bash
set -euo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

run_root() {
  if (( EUID == 0 )); then "$@"
  elif have sudo; then sudo "$@"
  else printf 'No hay privilegios root ni sudo; instala ShellCheck manualmente.\n' >&2; return 1
  fi
}

install_shellcheck() {
  if have apt-get; then
    run_root apt-get update
    run_root apt-get install -y shellcheck
  elif have dnf; then run_root dnf install -y ShellCheck
  elif have yum; then run_root yum install -y ShellCheck
  elif have zypper; then run_root zypper --non-interactive install ShellCheck
  elif have pacman; then run_root pacman -Sy --noconfirm shellcheck
  else
    printf 'No se reconoce un gestor de paquetes compatible. Instala ShellCheck manualmente y vuelve a ejecutar la suite.\n' >&2
    return 1
  fi
  have shellcheck || { printf 'El gestor terminó, pero shellcheck sigue sin estar disponible en PATH.\n' >&2; return 1; }
}

if have shellcheck; then exit 0; fi

mode="${SYSDIAG_SHELLCHECK_INSTALL:-ask}"
case "$mode" in
  1|yes|si|sí) install_shellcheck ;;
  0|no) exit 2 ;;
  ask)
    if [[ ! -t 0 || ! -t 1 ]]; then exit 2; fi
    printf 'ShellCheck no está instalado. ¿Quieres instalarlo para validar SYSdiag? [s/N]: '
    IFS= read -r answer || answer=""
    case "${answer,,}" in s|si|sí|y|yes) install_shellcheck ;; *) exit 2 ;; esac
    ;;
  *) printf 'SYSDIAG_SHELLCHECK_INSTALL admite ask, 1/yes o 0/no.\n' >&2; exit 2 ;;
esac
