#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
TMP="$TEST_TMP_ROOT/security-adversarial"; mkdir -p "$TMP/cwd"
BIN="$BASE_DIR/bin/sysdiag-linux-amd64"
[[ -x "$BIN" ]] || { printf 'SKIP: binario amd64 no disponible.\n'; exit 0; }
case "$(uname -m)" in x86_64|amd64) ;; *) printf 'SKIP: prueba portable amd64 en host no amd64.\n'; exit 0;; esac

# Un fichero llamado como el antiguo backend en el CWD nunca debe ejecutarse.
cat > "$TMP/cwd/sysdiag-legacy.sh" <<EOF_M
#!/usr/bin/env bash
echo pwned > "$TMP/cwd-executed"
exit 99
EOF_M
chmod +x "$TMP/cwd/sysdiag-legacy.sh"
(cd "$TMP/cwd" && "$BIN" --section memory --json > "$TMP/cwd.json")
[[ ! -e "$TMP/cwd-executed" ]] || fail 'el binario ejecutó un backend desde CWD'
python3 -m json.tool "$TMP/cwd.json" >/dev/null

# BASH_ENV/ENV no pueden inyectar código en el collector ejecutado por Go.
cat > "$TMP/evil-env.sh" <<EOF_E
printf injected > "$TMP/env-executed"
EOF_E
BASH_ENV="$TMP/evil-env.sh" ENV="$TMP/evil-env.sh" "$BIN" --section memory --json > "$TMP/env.json"
[[ ! -e "$TMP/env-executed" ]] || fail 'BASH_ENV/ENV se heredó al collector'

# Un override Kubernetes con ruta explícita debe ignorarse; no se ejecuta.
cat > "$TMP/evil-kubectl" <<EOF_K
#!/usr/bin/env bash
echo executed > "$TMP/kube-executed"
EOF_K
chmod +x "$TMP/evil-kubectl"
K8S_CLI_OVERRIDE="$TMP/evil-kubectl" "$BIN" --section kubernetes --k8s-no-auth-prompt --json > "$TMP/kube.json" || true
[[ ! -e "$TMP/kube-executed" ]] || fail 'se ejecutó K8S_CLI_OVERRIDE con ruta arbitraria'

# Un PATH marcado como confiable pero escribible por otros no se acepta.
mkdir -p "$TMP/worldbin"; chmod 0777 "$TMP/worldbin"
cat > "$TMP/worldbin/hostname" <<EOF_H
#!/usr/bin/env bash
echo compromised > "$TMP/path-executed"
/bin/hostname "\$@"
EOF_H
chmod +x "$TMP/worldbin/hostname"
SYSDIAG_TRUSTED_PATH="$TMP/worldbin:/usr/bin:/bin" "$BIN" --section memory --json > "$TMP/path.json"
[[ ! -e "$TMP/path-executed" ]] || fail 'se aceptó SYSDIAG_TRUSTED_PATH inseguro'

pass security-adversarial
